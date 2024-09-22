-- |
-- Module      : Streamly.Internal.Data.Ring
-- Copyright   : (c) 2019 Composewell Technologies
-- License     : BSD3
-- Maintainer  : streamly@composewell.com
-- Stability   : experimental
-- Portability : GHC
--
-- Unboxed, mutable ring arrays of fixed size. In case you need to expand the
-- size of a ring, copy it to a MutArray, expand the array and cast it back to
-- ring.

-- XXX Write benchmarks

module Streamly.Internal.Data.Ring
    ( Ring (..)

    -- * Debugging
    , showRing

    -- * Construction
    , createOfLast
    , castMutArray
    , castMutArrayWith
    , unsafeCastMutArray
    , unsafeCastMutArrayWith

    -- * Moving the Head
    , moveForward
    , moveReverse
    , moveBy

    -- * In-place Mutation
    -- introduce "insert" for expanding the ring
    -- expand by shifting the lesser half towards left or right
    , insert -- XXX change to "replace"
    , insert_
    , putIndex
    , modifyIndex

    -- * Random Access
    , getIndex
    , unsafeGetIndex
    , unsafeGetHead

    -- * Conversion
    , toList
    , toMutArray

    -- * Streams
    , read
    , readRev

    -- * Unfolds
    , reader
    , readerRev

    -- * Size
    , length
    , byteLength

    -- * Casting
    , cast
    , unsafeCast
    , asBytes
    , asMutArray
    , asMutArray_

    -- * Folds
    , foldlM'
    , fold

    -- * Stream of Rings
    , ringsOf
    , scanRingsOf
    , scanCustomFoldRingsBy
    , scanFoldRingsBy

    -- * Fast Byte Comparisons
    , eqArray
    , eqArrayN

    -- * Deprecated
    , unsafeFoldRing
    , unsafeFoldRingM
    , unsafeFoldRingNM
    , unsafeFoldRingFullM
    , slidingWindow
    , slidingWindowWith
    ) where

#include "ArrayMacros.h"
#include "inline.hs"

import Control.Monad (when)
import Control.Monad.IO.Class (MonadIO(..))
import Data.Proxy (Proxy(..))
import Data.Word (Word8)
import Fusion.Plugin.Types (Fuse(..))
import GHC.Types (SPEC(..))
import Streamly.Internal.Data.Array.Type (Array)
import Streamly.Internal.Data.MutArray.Type (MutArray(..))
import Streamly.Internal.Data.MutByteArray.Type (MutByteArray)
import Streamly.Internal.Data.Fold.Type (Fold(..), Step(..), lmap)
import Streamly.Internal.Data.Scanl.Type (Scanl(..))
import Streamly.Internal.Data.Stream.Step (Step(..))
import Streamly.Internal.Data.Stream.Type (Stream)
import Streamly.Internal.Data.Tuple.Strict (Tuple3Fused'(..))
import Streamly.Internal.Data.Unbox (Unbox(..))
import Streamly.Internal.Data.Unfold.Type (Unfold(..))

import qualified Streamly.Internal.Data.Array.Type as Array
import qualified Streamly.Internal.Data.Fold.Type as Fold
import qualified Streamly.Internal.Data.MutArray.Type as MutArray
import qualified Streamly.Internal.Data.Scanl.Type as Scanl
import qualified Streamly.Internal.Data.Stream.Transform as Stream
import qualified Streamly.Internal.Data.Stream.Type as Stream
-- import qualified Streamly.Internal.Data.Unfold as Unfold
-- XXX Add scanl benchmarks
-- XXX check split benchmarks

import Prelude hiding (length, concat, read)

-- $setup
-- >>> :m
-- >>> import qualified Streamly.Internal.Data.Fold as Fold
-- >>> import qualified Streamly.Internal.Data.MutArray as MutArray
-- >>> import qualified Streamly.Internal.Data.Ring as Ring
-- >>> import qualified Streamly.Internal.Data.Stream as Stream

-- XXX Need a feature in GHC to disable positional constructors for record
-- types, so that we can safely reorder the fields.
--
-- Empty (zero-sized) rings are not allowed in construction routines though the
-- code supports it. We can allow it if there is a compelling use case.
--
-- We could represent a ring as a tuple of array and ring head (MutArray a,
-- Int). The array never changes, only the head does so the array can be passed
-- as a constant in a loop.
--
-- Performance notes: Replacing the oldest item with the newest is a very
-- common operation, during this operation the only thing that changes is the
-- ring head. Updating the Ring constructor because of that could be expensive,
-- therefore, either the Ring constructor should be eliminated via fusion or we
-- should unbox it manually where needed to allow for only the head to change.

-- | A ring buffer is a circular buffer. A new element is inserted at a
-- position called the ring head which points to the oldest element in the
-- ring, an insert overwrites the oldest element. After inserting, the head is
-- moved to point to the next element which is now the oldest element.
--
-- Elements in the ring are indexed relative to the head. Ring head is
-- designated as the index 0 of the ring buffer, it points to the oldest or the
-- first element in the buffer. Higher positive indices point to the newer
-- elements in the buffer. Index @-1@ points to the newest or the last element
-- in the buffer. Higher negative indices point to older elements.
--
-- The ring is of fixed size and cannot be expanded or reduced after creation.
-- Creation of zero sized rings is not allowed.
--
-- This module provides an unboxed implementation of ring buffers for best
-- performance.
--
data Ring a = Ring
    { ringContents :: {-# UNPACK #-} !MutByteArray
    , ringSize :: {-# UNPACK #-} !Int -- size of array in bytes
    , ringHead :: {-# UNPACK #-} !Int -- byte index in the array
    }

-------------------------------------------------------------------------------
-- Construction
-------------------------------------------------------------------------------

-- | Given byte offset relative to the ring head, compute the linear byte
-- offset in the array. Offset can be positive or negative. Invariants:
--
-- * Ring size cannot be zero, this won't work correctly if so.
-- * Absolute value of offset must be less than or equal to the ring size.
-- * Offset must be integer multiple of element size.
{-# INLINE unsafeChangeHeadByOffset #-}
unsafeChangeHeadByOffset :: Int -> Int -> Int -> Int
unsafeChangeHeadByOffset rh rs i =
    let i1 = rh + i
     in if i1 >= rs
        then i1 - rs
        else if i1 < 0
             then i1 + rs
             else i1

-- | Convert a byte offset relative to the ring head to a byte offset in the
-- underlying mutable array. Offset can be positive or negative.
--
-- Throws an error if the offset is greater than or equal to the ring size.
{-# INLINE changeHeadByOffset #-}
changeHeadByOffset :: Int -> Int -> Int -> Int
changeHeadByOffset rh rs i =
    if i < rs && i > -rs
    then unsafeChangeHeadByOffset rh rs i
    else error $ "changeHeadByOffset: absolute value of offset must be less "
            ++ "than the ring size"

-- | Move the ring head forward or backward by n slots. Moves forward if the
-- argument is positive and backward if it is negative.
--
-- Throws an error if the absolute value of count is more than or euqal to the
-- ring size.
{-# INLINE moveBy #-}
moveBy :: forall a. Unbox a => Int -> Ring a -> Ring a
moveBy n rb =
    let i = changeHeadByOffset (ringHead rb) (ringSize rb) (n * SIZE_OF(a))
     in rb {ringHead = i}

-- | the offset must be exactly the element size in bytes.
{-# INLINE incrHeadByOffset #-}
incrHeadByOffset :: Int -> Int -> Int -> Int
incrHeadByOffset rh rs n =
    -- Note: This works even if the ring size is 0.
    let rh1 = rh + n
     -- greater than is needed when rs = 0
     in if rh1 >= rs
        then 0
        else rh1

-- | Advance the ring head forward by 1 slot, the ring head will now point to
-- the next (newer) item, and the old ring head position will become the latest
-- or the newest item position.
--
-- >>> moveForward = Ring.moveBy 1
--
{-# INLINE moveForward #-}
moveForward :: forall a. Unbox a => Ring a -> Ring a
moveForward rb@Ring{..} =
    rb { ringHead = incrHeadByOffset ringHead ringSize (SIZE_OF(a)) }

-- | the offset must be exactly the element size in bytes.
{-# INLINE decrHeadByOffset #-}
decrHeadByOffset :: Int -> Int -> Int -> Int
decrHeadByOffset rh rs n =
    -- Note: This works even if the ring size is 0.
    -- Though the head should never be accessed when ring size is 0, so it
    -- should not matter what it is.
    if rs /= 0
    then (if rh == 0 then rs else rh) - n
    else 0

-- | Move the ring head backward by 1 slot, the ring head will now point to
-- the prev (older) item, when the ring head is at the oldest item it will move
-- to the newest item.
--
-- >>> moveForward = Ring.moveBy (-1)
--
{-# INLINE moveReverse #-}
moveReverse :: forall a. Unbox a => Ring a -> Ring a
moveReverse rb@Ring{..} =
    rb { ringHead = decrHeadByOffset ringHead ringSize (SIZE_OF(a)) }

-------------------------------------------------------------------------------
-- Conversions
-------------------------------------------------------------------------------

-- | The array must not be a slice, and the index must be within the bounds of
-- the array otherwise unpredictable behavior will occur.
{-# INLINE unsafeCastMutArrayWith #-}
unsafeCastMutArrayWith :: forall a. Unbox a => Int -> MutArray a -> Ring a
unsafeCastMutArrayWith i arr =
    Ring
        { ringContents = arrContents arr
        , ringSize = arrEnd arr
        , ringHead = i * SIZE_OF(a)
        }

-- | Cast a MutArray to a ring sharing the same memory without copying. The
-- ring head is at index 0 of the array. The array must not be a slice.
--
-- >>> unsafeCastMutArray = Ring.unsafeCastMutArrayWith 0
--
{-# INLINE unsafeCastMutArray #-}
unsafeCastMutArray :: forall a. Unbox a => MutArray a -> Ring a
unsafeCastMutArray = unsafeCastMutArrayWith 0

-- XXX To avoid the failure we can either copy the array or have a ringStart
-- field in the ring. For copying we can have another API though.

-- XXX castMutArray is called unsafeFreeze in the Array module. Make the naming
-- consistent? Also we can use castMutArrayWith to specify the index and use
-- the default index 0.

-- | @castMutArray arr index@ casts a mutable array to a ring array having
-- the ring head at @index@ position in the array.
--
-- This operation throws an error if the index is not within the array bounds.
-- It returns Nothing if the array cannot be cast into ring because the array
-- is a slice. In that case clone the array and cast it or stream the array and
-- use 'createOfLast' to create a ring.
--
{-# INLINE castMutArrayWith #-}
castMutArrayWith :: forall a. Unbox a => Int -> MutArray a -> Maybe (Ring a)
castMutArrayWith i arr
    | i < 0 || i >= MutArray.length arr
        = error "castMutArray: index must not be negative or >= array size"
    | arrStart arr == 0
        = Just $ unsafeCastMutArrayWith i arr
    | otherwise = Nothing

-- | Cast a MutArray to a ring sharing the same memory without copying. The
-- ring head is at index 0 of the array. Cast fails with Nothing if the array
-- is a slice.
--
-- >>> castMutArray = Ring.castMutArrayWith 0
--
{-# INLINE castMutArray #-}
castMutArray :: forall a. Unbox a => MutArray a -> Maybe (Ring a)
castMutArray = castMutArrayWith 0

-------------------------------------------------------------------------------
-- Conversion to/from array
-------------------------------------------------------------------------------

-- | Modify a given index of a ring array using a modifier function.
--
-- /Unimplemented/
modifyIndex :: -- forall m a b. (MonadIO m, Unbox a) =>
    Int -> Ring a -> (a -> (a, b)) -> m b
modifyIndex = undefined

-- | /O(1)/ Write the given element at the given index relative to the current
-- position of the ring head. Index starts at 0, could be positive or negative.
--
-- Throws an error if the index is more than or equal to the size of the ring.
--
-- Performs in-place mutation of the array.
--
{-# INLINE putIndex #-}
putIndex :: forall m a. (MonadIO m, Unbox a) => Int -> Ring a -> a -> m ()
-- putIndex ix ring val = modifyIndex ix ring (const (val, ()))
putIndex i ring x =
    -- Note: ring must be of non-zero size.
    let j = changeHeadByOffset (ringHead ring) (ringSize ring) (i * SIZE_OF(a))
     in liftIO $ pokeAt j (ringContents ring) x

-- | Like 'insert' but does not return the old value of overwritten element.
--
-- Same as:
--
-- >>> insert_ rb x = Ring.putIndex 0 rb x >> pure (Ring.moveForward rb)
--
{-# INLINE insert_ #-}
insert_ :: forall m a. (MonadIO m, Unbox a) => Ring a -> a -> m (Ring a)
insert_ rb newVal = do
    -- Note poke will corrupt memory if the ring size is 0.
    when (ringSize rb /= 0)
        $ liftIO $ pokeAt (ringHead rb) (ringContents rb) newVal
    pure $ moveForward rb

-- | Return the element at the specified index without checking the bounds.
--
-- Unsafe because it does not check the bounds of the ring array.
{-# INLINE unsafeGetRawIndex #-}
unsafeGetRawIndex :: forall m a. (MonadIO m, Unbox a) => Int -> Ring a -> m a
unsafeGetRawIndex i ring = liftIO $ peekAt i (ringContents ring)

-- | Replace the oldest item in the ring (the item at the ring head) with a new
-- item and move the ring head to the remaining oldest item.
--
-- Throws an error if the ring is empty.
--
{-# INLINE insert #-}
insert :: forall m a. (MonadIO m, Unbox a) => Ring a -> a -> m (Ring a, a)
insert rb newVal = do
    -- Note: ring size cannot be zero.
    when (ringSize rb == 0) $
        error "insert: cannot insert in 0 sized ring"
    old <- unsafeGetRawIndex (ringHead rb) rb
    liftIO $ pokeAt (ringHead rb) (ringContents rb) newVal
    pure (moveForward rb, old)

-------------------------------------------------------------------------------
-- Random reads
-------------------------------------------------------------------------------

-- | Like 'getIndex' but does not check the bounds. Unpredictable behavior
-- occurs if the index is more than or equal to the ring size.
{-# INLINE unsafeGetIndex #-}
unsafeGetIndex :: forall m a. (MonadIO m, Unbox a) => Int -> Ring a -> m a
unsafeGetIndex i ring =
    let rs = ringSize ring
        j = unsafeChangeHeadByOffset (ringHead ring) rs (i * SIZE_OF(a))
     in unsafeGetRawIndex j ring

-- | /O(1)/ Lookup the element at the given index relative to the ring head.
-- Index starts from 0, could be positive or negative. Returns Nothing if the
-- index is more than or equal to the size of the ring.
--
{-# INLINE getIndex #-}
getIndex :: forall m a. (MonadIO m, Unbox a) => Int -> Ring a -> m (Maybe a)
getIndex i ring =
    let rs = ringSize ring
     in if i < rs && i > -rs
        then Just <$> unsafeGetIndex i ring
        else return Nothing

-- | /O(1)/ Lookup the element at the head position.
--
-- Prefer this over @unsafeGetIndex 0@ as it does not have have to perform an
-- index rollover check.
--
{-# INLINE unsafeGetHead #-}
unsafeGetHead :: (MonadIO m, Unbox a) => Ring a -> m a
unsafeGetHead ring = unsafeGetRawIndex (ringHead ring) ring

-------------------------------------------------------------------------------
-- Size
-------------------------------------------------------------------------------

-- | /O(1)/ Get the byte length of the ring.
--
{-# INLINE byteLength #-}
byteLength :: Ring a -> Int
byteLength = ringSize

-- | /O(1)/ Get the length of the ring. i.e. the number of elements in the
-- ring.
--
{-# INLINE length #-}
length :: forall a. Unbox a => Ring a -> Int
length rb = ringSize rb `div` SIZE_OF(a)

-------------------------------------------------------------------------------
-- Unfolds
-------------------------------------------------------------------------------

-- | Read the entire ring, starting at the ring head i.e. from oldest to
-- newest.
--
{-# INLINE_NORMAL reader #-}
reader :: forall m a. (MonadIO m, Unbox a) => Unfold m (Ring a) a
reader = Unfold step inject

    where

    inject rb = return (rb, ringSize rb)

    step (rb, n) = do
        if n <= 0
        then return Stop
        else do
            x <- unsafeGetHead rb
            return $ Yield x (moveForward rb, n - SIZE_OF(a))

-- | Read the entire ring, starting at the item before the ring head i.e. from
-- newest to oldest
--
{-# INLINE_NORMAL readerRev #-}
readerRev :: forall m a. (MonadIO m, Unbox a) => Unfold m (Ring a) a
readerRev = Unfold step inject

    where

    inject rb = return (rb, ringSize rb)

    step (rb, n) = do
        if n <= 0
        then return Stop
        else do
            let rb1 = moveReverse rb
            x <- unsafeGetHead rb1
            return $ Yield x (rb1, n - SIZE_OF(a))

-- | Read the entire ring as a stream, starting at the ring head i.e. from
-- oldest to newest.
--
{-# INLINE_NORMAL read #-}
read :: forall m a. (MonadIO m, Unbox a) => Ring a -> Stream m a
read = Stream.unfold reader

-- | Read the entire ring as a stream, starting from newest to oldest elements.
--
{-# INLINE_NORMAL readRev #-}
readRev :: forall m a. (MonadIO m, Unbox a) => Ring a -> Stream m a
readRev = Stream.unfold readerRev

-------------------------------------------------------------------------------
-- Stream of arrays
-------------------------------------------------------------------------------

-- | @scanRingsOf n@ groups the input stream into a stream of ring arrays of
-- size up to @n@. The first ring would be of size 1, then 2, and so on up to
-- size n, when size n is reached the ring starts sliding out the oldest
-- elements and keeps the newest n elements.
--
-- Note that the ring emitted is a mutable reference, therefore, should not be
-- retained without copying otherwise the contents will change in the next
-- iteration of the stream.
--
{-# INLINE scanRingsOf #-}
scanRingsOf :: forall m a. (MonadIO m, Unbox a) => Int -> Scanl m a (Ring a)
scanRingsOf n = Scanl step initial extract extract

    where

    initial =
        if n <= 0
        then error "ringsOf: window size must be > 0"
        else do
            arr :: MutArray.MutArray a <- liftIO $ MutArray.emptyOf n
            return $ Partial $ Tuple3Fused' (MutArray.arrContents arr) 0 0

    step (Tuple3Fused' mba rh i) a = do
        Ring _ _ rh1 <- insert_ (Ring mba (n * SIZE_OF(a)) rh) a
        return $ Partial $ Tuple3Fused' mba rh1 (i + 1)

    -- XXX exitify optimization causes a problem here when modular folds are
    -- used. Sometimes inlining "extract" is helpful.
    {-# INLINE extract #-}
    extract (Tuple3Fused' mba rh i) =
        let rs = min i n * SIZE_OF(a)
            rh1 = if i <= n then 0 else rh
         in pure $ Ring mba rs rh1

-- | @ringsOf n stream@ groups the input stream into a stream of ring arrays of
-- size up to n. See 'scanRingsOf' for more details.
--
{-# INLINE_NORMAL ringsOf #-}
ringsOf :: forall m a. (MonadIO m, Unbox a) =>
    Int -> Stream m a -> Stream m (Ring a)
ringsOf n = Stream.postscanl (scanRingsOf n)

-- XXX to keep the order intact use Ring.read. If order is not important for
-- the fold then we can use asMutArray which could be slightly faster.
-- f1 rb = Stream.fold f $ MutArray.read $ fst $ Ring.asMutArray rb

-- XXX the size and the array pointer are constant in the stream, only the head
-- changes on each tick. So we can just emit the head in the loop and keep the
-- size and pointer global.

{-# INLINE_NORMAL scanCustomFoldRingsBy #-}
scanCustomFoldRingsBy :: forall m a b. (MonadIO m, Unbox a) =>
    (Ring a -> m b) -> Int -> Scanl m a b
-- Custom Ring.fold performs better than the idiomatic implementations below,
-- perhaps because of some GHC optimization effect.
scanCustomFoldRingsBy f = Scanl.rmapM f . scanRingsOf

-- | Apply the given fold on sliding windows of the given size. Note that this
-- could be expensive because each operation goes through the entire window.
-- This should be used only if there is no efficient alternative way possible.
--
-- Examples:
--
-- >>> windowRange = Ring.scanFoldRingsBy Fold.range
-- >>> windowMinimum = Ring.scanFoldRingsBy Fold.minimum
-- >>> windowMaximum = Ring.scanFoldRingsBy Fold.maximum
--
{-# INLINE scanFoldRingsBy #-}
scanFoldRingsBy :: forall m a b. (MonadIO m, Unbox a) =>
    Fold m a b -> Int -> Scanl m a b
-- Custom Ring.fold performs better than the idiomatic implementations below,
-- perhaps because of some GHC optimization effect.
scanFoldRingsBy f = scanCustomFoldRingsBy (fold f)
-- scanFoldRingsBy f = Scanl.rmapM (fold f) . scanRingsOf
-- scanFoldRingsBy f = Scanl.rmapM (Unfold.fold f reader) . scanRingsOf
-- scanFoldRingsBy f = Scanl.rmapM (Stream.fold f . read) . scanRingsOf


-------------------------------------------------------------------------------
-- Construction
-------------------------------------------------------------------------------

-- | @createOfLast n@ returns the last n elements of the stream in a ring
-- array. @n@ must be non-zero.
--
{-# INLINE createOfLast #-}
createOfLast :: (Unbox a, MonadIO m) => Int -> Fold m a (Ring a)
createOfLast n = Fold.fromScanl $ scanRingsOf n

-------------------------------------------------------------------------------
-- Casting
-------------------------------------------------------------------------------

-- | Cast a ring having elements of type @a@ into a ring having elements of
-- type @b@. The ring size must be a multiple of the size of type @b@.
--
{-# INLINE unsafeCast #-}
unsafeCast :: Ring a -> Ring b
unsafeCast Ring{..} =
    Ring
        { ringContents = ringContents
        , ringHead = ringHead
        , ringSize = ringSize
    }

-- | Cast a @Ring a@ into a @Ring Word8@.
--
asBytes :: Ring a -> Ring Word8
asBytes = unsafeCast

-- | Cast a ring having elements of type @a@ into a ring having elements of
-- type @b@. The length of the ring should be a multiple of the size of the
-- target element otherwise 'Nothing' is returned.
--
{-# INLINE cast #-}
cast :: forall a b. (Unbox b) => Ring a -> Maybe (Ring b)
cast ring =
    let len = byteLength ring
        r = len `mod` SIZE_OF(b)
     in if r /= 0
        then Nothing
        else Just $ unsafeCast ring

-------------------------------------------------------------------------------
-- Equality
-------------------------------------------------------------------------------

-- | Like 'eqArray' but compares only N bytes instead of entire length of the
-- ring buffer. If N is bigger than the ring or array size, it is treated as an
-- error.
--
{-# INLINE eqArrayN #-}
eqArrayN :: Ring a -> Array a -> Int -> IO Bool
eqArrayN Ring{..} Array.Array{..} nBytes
    | nBytes < 0 = error "eqArrayN: n should be >= 0"
    | arrLen < nBytes = error "eqArrayN: array is shorter than n"
    | ringSize < nBytes = error "eqArrayN: ring is shorter than n"
    | nBytes == 0 = return True
    | otherwise = check ringHead 0

    where

    arrLen = arrEnd - arrStart

    -- XXX compare Word64 at a time
    check ringIndex arrayIndex = do
        (relem :: Word8) <- peekAt ringIndex ringContents
        aelem <- peekAt arrayIndex arrContents
        if relem == aelem
        then go (ringIndex + 1) (arrayIndex + 1)
        else return False

    go ringIndex arrayIndex
        -- Checking ringIndex == rh is enough
        --  | arrayIndex == nBytes = return True
        | ringIndex == ringSize = go 0 arrayIndex
        | ringIndex == ringHead = return True
        | otherwise = check ringIndex arrayIndex

-- XXX We can use memcmp over two segments.

-- | Byte compare the entire length of ringBuffer with the given array,
-- starting at the supplied ring head index.  Returns true if the Array and
-- the ring have identical contents. If the array is bigger checks only
-- up to the ring length. If array is shorter than then ring, it is treated as
-- an error.
--
{-# INLINE eqArray #-}
eqArray :: Ring a -> Array a -> IO Bool
eqArray Ring{..} Array.Array{..}
    | arrLen < ringSize = error "eqArrayN: array is shorter than ring"
    | otherwise = check ringHead 0

    where

    arrLen = arrEnd - arrStart

    -- XXX compare Word64 at a time
    check ringIndex arrayIndex = do
        (relem :: Word8) <- peekAt ringIndex ringContents
        aelem <- peekAt arrayIndex arrContents
        if relem == aelem
        then go (ringIndex + 1) (arrayIndex + 1)
        else return False

    go ringIndex arrayIndex
        | ringIndex == ringSize = go 0 arrayIndex
        | ringIndex == ringHead = return True
        | otherwise = check ringIndex arrayIndex

-------------------------------------------------------------------------------
-- Folding
-------------------------------------------------------------------------------

-- Note: INLINE_NORMAL is important for use in scanFoldRingsBy

-- | Fold the entire length of a ring buffer starting at the current ring head.
--
{-# INLINE_NORMAL fold #-}
fold :: forall m a b. (MonadIO m, Unbox a)
    => Fold m a b -> Ring a -> m b
-- These are slower when used in a scan extract. One of the issues is the
-- exitify optimization, there could be others.
-- fold f rb = Unfold.fold f reader rb
-- fold f rb = Stream.fold f $ read rb
fold (Fold step initial _ final) rb = do
    res <- initial
    case res of
        Fold.Partial fs -> go SPEC rh fs
        Fold.Done b -> return b

    where

    rh = ringHead rb

    -- Note: Passing the SPEC arg seems to give better results in windowRange
    -- benchmarks for larger windows, while worse results for smaller windows.
    {-# INLINE go #-}
    go !_ index !fs = do
        x <- unsafeGetRawIndex index rb
        r <- step fs x
        case r of
            Fold.Done b -> return b
            Fold.Partial s -> do
                let next = incrHeadByOffset index (ringSize rb) (SIZE_OF(a))
                if next == rh
                then final s
                else go SPEC next s

-- XXX This was for folding when the ring is not full, now we do not support
-- that so this should not be needed.

-- | Fold the buffer starting from ringStart up to the given index using a pure
-- step function. This is useful to fold the items in the ring when the ring is
-- not full. The supplied index is usually the end of the ring.
--
-- Unsafe because the supplied index is not checked to be in range.
{-# DEPRECATED unsafeFoldRing "This function will be removed in future." #-}
{-# INLINE unsafeFoldRing #-}
unsafeFoldRing :: forall a b. Unbox a
    => Int -> (b -> a -> b) -> b -> Ring a -> IO b
unsafeFoldRing !len f z rb = go z 0

    where

    go !acc !index
        | index == len = return acc
        | otherwise = do
            x <- unsafeGetRawIndex index rb
            go (f acc x) (index + SIZE_OF(a))

-- | Like unsafeFoldRing but with a monadic step function.
{-# DEPRECATED unsafeFoldRingM "This function will be removed in future." #-}
{-# INLINE unsafeFoldRingM #-}
unsafeFoldRingM :: forall m a b. (MonadIO m, Unbox a)
    => Int -> (b -> a -> m b) -> b -> Ring a -> m b
unsafeFoldRingM !len f z rb = go z 0

    where

    go !acc !index
        | index == len = return acc
        | otherwise = do
            x <- unsafeGetRawIndex index rb
            acc1 <- f acc x
            go acc1 (index + SIZE_OF(a))

-- | Fold the entire length of a ring buffer starting at the current ring head.
--
-- Note, this will crash on ring of 0 size.
--
{-# INLINE foldlM' #-}
foldlM' :: forall m a b. (MonadIO m, Unbox a)
    => (b -> a -> m b) -> b -> Ring a -> m b
foldlM' f z = fold (Fold.foldlM' f (pure z))

-- These are slower when used in a scan extract. One of the issues is the
-- exitify optimization, there could be others.
-- foldlM' f z rb = Unfold.fold (Fold.foldlM' f (pure z)) reader rb
-- foldlM' f z rb = Stream.fold (Fold.foldlM' f (pure z)) $ read rb

{-
foldlM' f z rb = go z rh

    where

    rh = ringHead rb

    go !acc !index = do
        x <- unsafeGetRawIndex index rb
        acc' <- f acc x
        let next = incrHeadByOffset index (ringSize rb) (SIZE_OF(a))
        if next == rh
        then return acc'
        else go acc' next
-}

{-# DEPRECATED unsafeFoldRingFullM "This function will be removed in future." #-}
{-# INLINE unsafeFoldRingFullM #-}
unsafeFoldRingFullM :: forall m a b. (MonadIO m, Unbox a)
    => (b -> a -> m b) -> b -> Ring a -> m b
unsafeFoldRingFullM = foldlM'

-- | Fold @n@ items in the ring starting at the ring head. Won't fold more
-- than the length of the ring even if @n@ is larger.
--
-- Note, this will crash on ring of 0 size.
--
{-# DEPRECATED unsafeFoldRingNM "This function will be removed in future." #-}
{-# INLINE unsafeFoldRingNM #-}
unsafeFoldRingNM :: forall m a b. (MonadIO m, Unbox a)
    => Int -> (b -> a -> m b) -> b -> Ring a -> m b
unsafeFoldRingNM count f z rb = go count z rh

    where

    rh = ringHead rb

    go 0 acc _ = return acc
    go !n !acc !index = do
        x <- unsafeGetRawIndex index rb
        acc' <- f acc x
        let next = unsafeChangeHeadByOffset index (ringSize rb) (SIZE_OF(a))
        if next == rh || n == 0
            then return acc'
            else go (n - 1) acc' next

-- | Cast the ring to a mutable array. Return the mutable array as well as the
-- current position of the ring head. Note that the array does not start with
-- the current ring head. The array refers to the same memory as the ring.
{-# INLINE asMutArray #-}
asMutArray :: Ring a -> (MutArray a, Int)
asMutArray rb =
    ( MutArray
        { arrContents = ringContents rb
        , arrStart = 0
        , arrEnd = ringSize rb
        , arrBound = ringSize rb
        }
    , ringHead rb
    )

{-# INLINE asMutArray_ #-}
asMutArray_ :: Ring a -> MutArray a
asMutArray_ rb =
    MutArray
        { arrContents = ringContents rb
        , arrStart = 0
        , arrEnd = ringSize rb
        , arrBound = ringSize rb
        }

-- XXX We can use bulk copy using memcpy or at least a Word64 at a time.

-- | Copy the ring to a MutArray, the first element of the MutArray is the
-- oldest element of the ring (i.e. ring head) and the last is the newest.
--
-- >>> toMutArray rb = Stream.fold (MutArray.createOf (Ring.length rb)) $ Ring.read rb
--
{-# INLINE toMutArray #-}
toMutArray :: (MonadIO m, Unbox a) => Ring a -> m (MutArray a)
toMutArray rb = MutArray.fromStreamN (length rb) $ read rb
{-
toMutArray rb = do
    -- Using unpinned array here instead of pinned
    arr <- liftIO $ MutArray.emptyOf (length rb)
    let snoc' b a = liftIO $ MutArray.unsafeSnoc b a
    foldlM' snoc' arr rb
-}

-- | Copy the ring to a list, the first element of the list is the oldest
-- element of the ring (i.e. ring head) and the last is the newest.
--
-- >>> toList = Stream.toList . Ring.read
--
{-# INLINE toList #-}
toList :: (MonadIO m, Unbox a) => Ring a -> m [a]
toList = Stream.toList . read

-- | Show the contents of a Ring as a list.
--
-- >>> showRing rb = Ring.toList rb >>= return . show
--
showRing :: (Unbox a, Show a) => Ring a -> IO String
showRing rb = show <$> toList rb

{-# ANN type SlidingWindow Fuse #-}
data SlidingWindow a s = SWArray !a !Int !s !Int | SWRing !a !Int !s

-- | Like slidingWindow but also provides the entire ring contents as an Array.
-- The array reflects the state of the ring after inserting the incoming
-- element.
--
-- IMPORTANT NOTE: The ring is mutable, therefore, the result of @(m (Array
-- a))@ action depends on when it is executed. It does not capture the sanpshot
-- of the ring at a particular time.
{-# DEPRECATED slidingWindowWith "Please use Scanl.incrScanWith instead." #-}
{-# INLINE slidingWindowWith #-}
slidingWindowWith :: forall m a b. (MonadIO m, Unbox a)
    => Int -> Fold m ((a, Maybe a), m (MutArray a)) b -> Fold m a b
slidingWindowWith n (Fold step1 initial1 extract1 final1) =
    Fold step initial extract final

    where

    initial = do
        if n <= 0
        then error "Window size must be > 0"
        else do
            r <- initial1
            arr :: MutArray.MutArray a <- liftIO $ MutArray.emptyOf n
            return $
                case r of
                    Partial s -> Partial
                        $ SWArray (MutArray.arrContents arr) 0 s n
                    Done b -> Done b

    step (SWArray mba rh st i) a = do
        Ring _ _ rh1 <- insert_ (Ring mba (n * SIZE_OF(a)) rh) a
        let size = (n - i) * SIZE_OF(a)
        r <- step1 st ((a, Nothing), pure (MutArray mba 0 size size))
        return $
            case r of
                Partial s ->
                    if i > 0
                    then Partial $ SWArray mba rh1 s (i-1)
                    else Partial $ SWRing mba rh1 s
                Done b -> Done b

    step (SWRing mba rh st) a = do
        (rb1@(Ring _ _ rh1), old) <- insert (Ring mba (n * SIZE_OF(a)) rh) a
        r <- step1 st ((a, Just old), toMutArray rb1)
        return $
            case r of
                Partial s -> Partial $ SWRing mba rh1 s
                Done b -> Done b

    extract (SWArray _ _ st _) = extract1 st
    extract (SWRing _ _ st) = extract1 st

    final (SWArray _ _ st _) = final1 st
    final (SWRing _ _ st) = final1 st

-- | @slidingWindow collector@ is an incremental sliding window
-- fold that does not require all the intermediate elements in a computation.
-- This maintains @n@ elements in the window, when a new element comes it slides
-- out the oldest element and the new element along with the old element are
-- supplied to the collector fold.
--
-- The 'Maybe' type is for the case when initially the window is filling and
-- there is no old element.
--
{-# DEPRECATED slidingWindow "Please use Scanl.incrScan instead." #-}
{-# INLINE slidingWindow #-}
slidingWindow :: forall m a b. (MonadIO m, Unbox a)
    => Int -> Fold m (a, Maybe a) b -> Fold m a b
slidingWindow n f = slidingWindowWith n (lmap fst f)
