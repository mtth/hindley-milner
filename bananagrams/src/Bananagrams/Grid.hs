{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TypeApplications #-}

-- | Bananagrams grid operations
module Bananagrams.Grid (
  -- * Construction
  Grid, newGrid,
  -- * Accessors
  Entry(..), Orientation(..), orientationYX, currentEntries,
  -- * Modification
  -- ** Primitives
  Conflict(..), setEntry, unsetLastEntry,
  -- ** Candidate locations
  Candidate(..), candidates,
  -- * Debugging
  displayGrid, displayEntries
) where

import Algebra.Lattice (joins1, meets1)
import Control.Applicative ((<|>))
import Control.Monad (when)
import Control.Monad.Extra (firstJustM)
import Control.Monad.ST (ST, runST)
import Control.Monad.State.Strict (get, modify, put, runStateT)
import Control.Monad.Trans.Class (lift)
import qualified Data.Array.IArray as IArray
import qualified Data.Array.MArray as MArray
import Data.Array.ST (STUArray)
import Data.Array.Unboxed (UArray)
import qualified Data.Array.Unsafe as Array
import Data.Bits ((.&.), clearBit, popCount, setBit, shiftR)
import Data.ByteString (ByteString)
import qualified Data.ByteString.Char8 as BS
import Data.Char (chr, ord)
import Data.Foldable (foldl', for_, toList)
import Data.Geometry.YX (YX(..))
import qualified Data.Geometry.YX as YX
import Data.List.NonEmpty (NonEmpty(..))
import Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map
import Data.Maybe (catMaybes)
import Data.Multiset (Multiset)
import qualified Data.Multiset as Multiset
import Data.Sequence (Seq)
import qualified Data.Sequence as Seq
import Data.Set (Set)
import qualified Data.Set as Set
import Data.STRef (STRef, modifySTRef', newSTRef, readSTRef, writeSTRef)
import Data.Text (Text)
import qualified Data.Text as T
import Data.Word (Word16)
import Debug.Trace (trace)

-- | An entry's orientation.
data Orientation = Horizontal | Vertical deriving (Eq, Ord, Enum, Bounded, Show)

-- | The unit vector corresponding to the orientation.
orientationYX :: Orientation -> YX
orientationYX Horizontal = YX.right
orientationYX Vertical = YX.down

otherOrientation :: Orientation -> Orientation
otherOrientation Horizontal = Vertical
otherOrientation Vertical = Horizontal

data Direction = U | L | D | R deriving (Eq, Ord, Enum, Bounded, Show)

directionYX :: Direction -> YX
directionYX U = YX.up
directionYX L = YX.left
directionYX D = YX.down
directionYX R = YX.right

directions :: [Direction]
directions = [U, L, D, R]


-- | A type alias for values stored in a grid. This is useful to be able to store them in an
-- efficient unboxed array.
type Letter = Word16

unknownLetter :: Letter
unknownLetter = 0

letterChar :: Letter -> Char
letterChar letter = if letterCount letter == 0
  then ' '
  else chr $ fromIntegral $ letter .&. 255

letterCount :: Letter -> Int
letterCount letter = fromIntegral $ shiftR letter 8 .&. 15

-- | Returns a letter updated to contain the character. If the letter was already populated (i.e.
-- had a positive 'letterCount') with a different character or if called more than 31 times,
-- 'setChar' will return 'Nothing'.
setChar :: Char -> Letter -> Maybe Letter
setChar char letter =
  let
    char' = letterChar letter
    letter' = (letter .&. 65280) + 256 + fromIntegral (ord char)
  in if char' == ' ' || char' == char
    then Just letter'
    else Nothing

unsetChar :: Letter -> Letter
unsetChar letter = letter - 256

-- | A word entry inside a grid.
data Entry
  = Entry
    { entryText :: !Text
    , entryOrientation :: !Orientation
    , entryStart :: !YX
    } deriving (Eq, Ord, Show)

entryEnd :: Entry -> YX
entryEnd (Entry txt orient start) = start + fromIntegral (T.length txt - 1) * orientationYX orient

entryYXs :: Entry -> [YX]
entryYXs entry = MArray.range (entryStart entry, entryEnd entry)

-- | The impact of an entry on the grid. This is useful to 
data Change
  = Change
    { changeEntry :: !Entry -- ^ The entry responsible for the change.
    , changeBlocks :: !(Multiset YX) -- ^ The blocks generated by adding this entry.
    , changeChars :: !(Multiset Char)
    -- ^ The characters required for inserting the entry. Note that these might be a strict subset
    -- of the entry's if existing characters were reused.
    } deriving Show

-- | A Bananagrams grid!
data Grid s
  = Grid
    { gridChanges :: !(STRef s (Seq Change))
    -- ^ All entries currently set in the grid.
    , gridBlocks :: !(STRef s (Multiset YX))
    -- ^ The positions where no character should go. These include the positions right before and
    -- after each entry and around intersections.
    , gridLetters :: !(STUArray s YX Letter)
    -- ^ The 2D grid, with the entries' characters, space if not populated.
    }

-- | Generates a new grid of edge length @2*n+1@, centered around 0.
newGrid :: Int -> ST s (Grid s)
newGrid size =
  let
    yx = YX (size + 2) (size + 2) -- Pad to simplify neighbor handling.
    arr = MArray.newArray (-yx, yx) unknownLetter
  in Grid <$> newSTRef Seq.empty <*> newSTRef Multiset.empty <*> arr

-- | All entries set in the grid.
currentEntries :: Grid s -> ST s [Entry]
currentEntries grid = fmap changeEntry . toList <$> readSTRef (gridChanges grid)

modifyArray :: MArray.MArray a e m => a YX e -> YX -> (e -> e) -> m ()
modifyArray arr yx f = do
  v <- MArray.readArray arr yx
  MArray.writeArray arr yx (f v)

-- | A conflict when adding an entry.
data Conflict
  = Conflict
    { conflictYX :: !YX
    , conflictNewChar :: Char
    , conflictOldChar :: Maybe Char -- ^ Nothing if the position can not be populated.
    } deriving (Eq, Ord, Show)

entryChars :: Entry -> [(YX, Char)]
entryChars (Entry txt orient start) =
  let dyx = orientationYX orient
  in zip (iterate (+dyx) start) (T.unpack txt)

diagonals :: YX -> Orientation -> ([YX], [YX])
diagonals coord orient =
  let
    dyx = orientationYX orient
    dyx' = orientationYX $ otherOrientation orient
    coords yx = let yx' = coord + yx in [yx' - dyx', yx' + dyx']
  in (coords (-dyx), coords dyx)

-- | Attempts to add a new entry to the grid. Note that this method does *not* check that a word is
-- valid. If the word is empty or does not fit in the grid, this method will 'error'.
setEntry :: Entry -> Grid s -> ST s (Either Conflict (Multiset Char))
setEntry entry grid = case T.length (entryText entry) of
  0 -> error "null entry"
  len -> do
    oldBlocks <- readSTRef $ gridBlocks grid
    let
      pairs = entryChars entry
      orient = entryOrientation entry
      letters = gridLetters grid
      dyx = orientationYX orient
      start = entryStart entry - dyx
      end = entryEnd entry + dyx
      initialChange = Change entry (Multiset.fromList [start, end]) Multiset.empty

      buildChange (i, (yx, char)) = if Multiset.member yx oldBlocks
        then pure . Just $ Conflict yx char Nothing
        else do
          letter <- lift $ MArray.readArray letters yx
          let
            char' = letterChar letter
            count = letterCount letter
          if count > 0 && char /= char'
            then pure . Just $ Conflict yx char (Just char')
            else do
              Change _ blocks chars <- get
              let
                (diags1, diags2) = diagonals yx orient
                blocks1 = if i == 0 then Multiset.empty else Multiset.fromList diags1
                blocks2 = if i == (len-1) then Multiset.empty else Multiset.fromList diags2
                blocks' = if count == 0 then blocks else blocks <> blocks1 <> blocks2
                chars' = if count == 0 then Multiset.insert char chars else chars
              put $ Change entry blocks' chars'
              pure Nothing

      applyChange change = do
        let
          updateLetter (yx, char) = modifyArray letters yx $ \l -> case setChar char l of
            Nothing -> error "conflict" -- Should not happen.
            Just l' -> l'
        traverse updateLetter pairs
        modifySTRef' (gridChanges grid) (Seq.|> change)
        modifySTRef' (gridBlocks grid) (<> changeBlocks change)

    runStateT (firstJustM buildChange $ zip [0..] pairs) initialChange >>= \case
      (Just conflict, _) -> pure $ Left conflict
      (Nothing, change) -> do
        applyChange change
        pure . Right $ changeChars change

-- | Removes the last added entry, or does nothing if the grid doesn't contain any entries. Returns
-- the entry which was just unset, if any.
unsetLastEntry :: Grid s -> ST s (Multiset Char)
unsetLastEntry grid = readSTRef (gridChanges grid) >>= \case
  Seq.Empty -> pure Multiset.empty
  changes Seq.:|> change -> do
    let
      entry = changeEntry change
      letters = gridLetters grid
      updateLetter (yx, _) = modifyArray letters yx unsetChar
    traverse updateLetter $ entryChars entry
    writeSTRef (gridChanges grid) changes
    modifySTRef' (gridBlocks grid) (flip Multiset.difference $ changeBlocks change)
    pure $ changeChars change

-- | Returns the smallest box containing all input entries, or nothing if no entries were given.
entriesBox :: [Entry] -> Maybe YX.Box
entriesBox entries = case entries of
  [] -> Nothing
  entry : entries' ->
    let entries'' = entry :| toList entries'
    in YX.box (meets1 $ fmap entryStart entries'') (joins1 $ fmap entryEnd entries'')

-- | A point from which a grid can be extended.
data ExtensionPoint
  = ExtensionPoint
    { extensionPointYX :: !YX
    , extensionPointChar :: !Char
    , extensionPointDirection :: !Orientation }

-- | Returns all extension points inside the grid.
extensionPoints :: Grid s -> ST s [ExtensionPoint]
extensionPoints grid = do
  entries <- currentEntries grid
  let
    letters = gridLetters grid
    toPoint orient yx = do
      letter <- MArray.readArray letters yx
      if letterCount letter > 1
        then pure Nothing
        else pure . Just $ ExtensionPoint yx (letterChar letter) orient
    toTuples entry = traverse (toPoint $ entryOrientation entry) $ entryYXs entry
  catMaybes . concat <$> traverse toTuples entries

-- | A candidate grid location.
data Candidate
  = Candidate
    { candidateYX :: !YX
    -- ^ The candidate root coordinate, always already set in the grid.
    , candidateOrientation :: !Orientation
    -- ^ The orientation of the new word.
    , candidateChars :: !(Map Int Char)
    -- ^ All set characters in this candidate row or column, indexed from the root.
    , candidateBounds :: !(Int, Int)
    -- ^ Minimum and maximum offsets for this candidate position. Note that the maximum candidate
    -- word length can be inferred from these bounds (
    } deriving (Eq, Ord, Show)

-- | Returns all candidate locations for adding new words to the grid. Note that word expansions are
-- not considered valid candidates (e.g. @T@ transforming @CAT@ into @CATS@ would not be returned).
-- The first argument is used to limit the sweep, it should be set to the maximum length of the word
-- set in these positions + 1.
candidates :: Int -> Grid s -> ST s [Candidate]
candidates maxBound grid = do
  blocks <- readSTRef $ gridBlocks grid
  entries <- currentEntries grid
  let letters = gridLetters grid
  Just box <- uncurry YX.box <$> MArray.getBounds letters

  let
    toCandidate (ExtensionPoint yx char orient) = do
      let
        orient' = otherOrientation orient
        coordDelta = orientationYX orient'

        findBound mul dyx@(YX dy dx) offset =
          let yx' = yx + YX (offset * dy) (offset * dx)
          in if Multiset.member yx' blocks || not (yx' `YX.inBox` box)
            then pure $ offset - 1
            else do
              letter <- lift $ MArray.readArray letters yx'
              when (letterCount letter > 0) $ modify $ Map.insert (mul * offset) $ letterChar letter
              if offset == maxBound then pure offset else findBound mul dyx (offset + 1)

      (bounds, chars) <- flip runStateT (Map.singleton 0 char) $ do
        leftBound <- findBound (-1) (- coordDelta) 1
        rightBound <- findBound 1 coordDelta 1
        pure (leftBound, rightBound)

      pure $ Candidate yx orient' chars bounds

    isExtensible cand = let (left, right) = candidateBounds cand in left > 0 || right > 0
  points <- extensionPoints grid
  filter isExtensible <$> traverse toCandidate points

-- | Formats a grid into a string. See 'displayEntries' for a convenience wrapper for common
-- use-cases.
displayGrid :: Grid s -> ST s ByteString
displayGrid grid = fmap entriesBox (currentEntries grid) >>= \case
  Nothing -> pure ""
  Just box -> do
    letters <- Array.unsafeFreeze $ gridLetters grid
    let subLetters = IArray.ixmap @UArray (YX.topLeft box, YX.bottomRight box) id letters
    pure $ YX.arrayToByteString letterChar subLetters

catLefts :: [Either a b] -> [a]
catLefts = go where
  go [] = []
  go (Left a : es) = a : go es
  go (_ : es) = go es

-- | Returns a human-readable representation of the entries.
displayEntries :: [Entry] -> Either Conflict ByteString
displayEntries entries =
  let yxs = concat $ fmap (\e -> [entryStart e, entryEnd e]) entries
  in case concat $ fmap (\(YX y x) -> [abs x, abs y]) yxs of
    [] -> Right ""
    vs -> runST $ do
        grid <- newGrid $ maximum vs
        conflicts <- catLefts <$> traverse (\e -> setEntry e grid) entries
        case conflicts of
          [] -> Right <$> displayGrid grid
          conflict : _ -> pure $ Left conflict
