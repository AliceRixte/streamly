{-# LANGUAGE CPP #-}
-- |
-- Module      : Streamly.Data.Stream
-- Copyright   : (c) 2017 Composewell Technologies
--
-- License     : BSD3
-- Maintainer  : streamly@composewell.com
-- Stability   : released
-- Portability : GHC
--
-- The 'Stream' type represents a producer of a sequence of values, the
-- corresponding dual type is 'Streamly.Data.Fold.Fold' which represents a
-- consumer. Both types can perform equivalent transformations on a stream. But
-- only 'Fold' can be used to compose multiple consumers and only 'Stream' can
-- be used to compose multiple producers.
--
-- The 'Stream' type represents streams as state machines, that fuse together
-- when composed statically, eliminating function calls or intermediate
-- constructor allocations. Stream fusion helps generate tight, efficient loops
-- similar to the code generated by low-level languages like C. Streams are
-- suitable for high-performance looping operations.
--
-- Operations in this module are not meant to be used recursively. In other
-- words, they are supposed to be composed statically rather than dynamically.
-- For dynamic, recursive composition use the continuation passing style (CPS)
-- stream operations from the "Streamly.Data.StreamK" module. 'Stream' and
-- 'Streamly.Data.StreamK.StreamK' types are interconvertible.
--
-- Operations in this module are designed to be composed statically rather than
-- dynamically. They are inlined to enable static fusion. More importantly,
-- they are not designed to be used recursively. Recursive use will break
-- fusion and will lead to quadratic performance slowdown. For dynamic or
-- recursive composition use the continuation passing style (CPS) operations
-- from the "Streamly.Data.StreamK" module. 'Stream' and
-- 'Streamly.Data.StreamK.StreamK' types are interconvertible.
--
-- Please refer to "Streamly.Internal.Data.Stream" for more functions that have
-- not yet been released.
--
-- Checkout the <https://github.com/composewell/streamly-examples>
-- repository for many more real world examples of stream programming.
--
-- == Console Echo Example
--
-- Here is an example of program which reads lines from console and writes them
-- back to the console. It is a simple example of a declarative loop written
-- using streaming combinators.  Compare it with an imperative @while@ loop
-- used to write a similar program.
--
-- >>> import Data.Function ((&))
-- >>> :{
-- echo =
--  Stream.repeatM getLine       -- Stream IO String
--      & Stream.mapM putStrLn   -- Stream IO ()
--      & Stream.fold Fold.drain -- IO ()
-- :}
--
-- In this example, 'repeatM' generates an infinite stream of 'String's by
-- repeatedly performing the 'getLine' IO action. 'mapM' then applies
-- 'putStrLn' on each element in the stream converting it to stream of '()'.
-- Finally, 'Streamly.Data.Fold.drain' 'fold's the stream to IO discarding the
-- () values, thus producing only effects.
--
-- Hopefully, this gives you an idea of how we can program declaratively by
-- representing loops using streams. In this module, you can find all
-- "Data.List"-like functions and many more powerful combinators to perform
-- common programming tasks.
--

module Streamly.Data.Stream
    (
    -- * Setup
    -- | To execute the code examples provided in this module in ghci, please
    -- run the following commands first.
    --
    -- $setup

    -- * Overview
    -- $overview

    -- * The Stream Type
      Stream

    -- * Construction
    -- | Functions ending in the general shape @b -> Stream m a@.
    --
    -- Useful Idioms:
    --
    -- >>> fromIndices f = fmap f $ Stream.enumerateFrom 0
    -- >>> fromIndicesM f = Stream.mapM f $ Stream.enumerateFrom 0
    -- >>> fromListM = Stream.sequence . Stream.fromList
    -- >>> fromFoldable = StreamK.toStream . StreamK.fromFoldable
    -- >>> fromFoldableM = Stream.sequence . fromFoldable

    -- ** Primitives
    -- | These primitives are meant to statically fuse a small number of stream
    -- elements. The 'Stream' type is never constructed at large scale using
    -- these primitives. Use 'StreamK' if you need to construct a stream from
    -- primitives.
    , nil
    , nilM
    , cons
    , consM

    -- ** Unfolding
    -- | 'unfoldrM' is the most general way of generating a stream efficiently.
    -- All other generation operations can be expressed using it.
    , unfoldr
    , unfoldrM

    -- ** Singleton
    , fromPure
    , fromEffect

    -- ** Iteration
    -- | Generate a monadic stream from a seed value or values.
    --
    , iterate
    , iterateM
    , repeat
    , repeatM
    , replicate
    , replicateM

    -- ** Enumeration
    -- | 'Enumerable' type class is to streams as 'Enum' is to lists. Enum
    -- provides functions to generate a list, Enumerable provides similar
    -- functions to generate a stream instead.
    --
    -- It is much more efficient to use 'Enumerable' directly than enumerating
    -- to a list and converting it to stream. The following works but is not
    -- particularly efficient:
    --
    -- >>> f from next = Stream.fromList $ Prelude.enumFromThen from next
    --
    -- Note: For lists, using enumeration functions e.g. 'Prelude.enumFromThen'
    -- turns out to be slightly faster than the idioms like @[from, then..]@.

    , Enumerable (..)
    , enumerate
    , enumerateTo

    -- ** From Containers
    -- | Convert an input structure, container or source into a stream. All of
    -- these can be expressed in terms of primitives.
    , fromList

    -- ** From Unfolds
    -- | Most of the above stream generation operations can also be expressed
    -- using the corresponding unfolds in the "Streamly.Data.Unfold" module.
    , unfold -- XXX rename to fromUnfold?

    -- * Elimination
    -- | Functions ending in the general shape @Stream m a -> m b@ or @Stream m
    -- a -> m (b, Stream m a)@
    --

-- EXPLANATION: In imperative terms a fold can be considered as a loop over the stream
-- that reduces the stream to a single value.
-- Left and right folds both use a fold function @f@ and an identity element
-- @z@ (@zero@) to deconstruct a recursive data structure and reconstruct a
-- new data structure. The new structure may be a recursive construction (a
-- container) or a non-recursive single value reduction of the original
-- structure.
--
-- Both right and left folds are mathematical duals of each other, they are
-- functionally equivalent.  Operationally, a left fold on a left associated
-- structure behaves exactly in the same way as a right fold on a right
-- associated structure. Similarly, a left fold on a right associated structure
-- behaves in the same way as a right fold on a left associated structure.
-- However, the behavior of a right fold on a right associated structure is
-- operationally different (even though functionally equivalent) than a left
-- fold on the same structure.
--
-- On right associated structures like Haskell @cons@ lists or Streamly
-- streams, a lazy right fold is naturally suitable for lazy recursive
-- reconstruction of a new structure, while a strict left fold is naturally
-- suitable for efficient reduction. In right folds control is in the hand of
-- the @puller@ whereas in left folds the control is in the hand of the
-- @pusher@.
--
-- The behavior of right and left folds are described in detail in the
-- individual fold's documentation.  To illustrate the two folds for right
-- associated @cons@ lists:
--
-- > foldr :: (a -> b -> b) -> b -> [a] -> b
-- > foldr f z [] = z
-- > foldr f z (x:xs) = x `f` foldr f z xs
-- >
-- > foldl :: (b -> a -> b) -> b -> [a] -> b
-- > foldl f z [] = z
-- > foldl f z (x:xs) = foldl f (z `f` x) xs
--
-- @foldr@ is conceptually equivalent to:
--
-- > foldr f z [] = z
-- > foldr f z [x] = f x z
-- > foldr f z xs = foldr f (foldr f z (tail xs)) [head xs]
--
-- @foldl@ is conceptually equivalent to:
--
-- > foldl f z [] = z
-- > foldl f z [x] = f z x
-- > foldl f z xs = foldl f (foldl f z (init xs)) [last xs]
--
-- Left and right folds are duals of each other.
--
-- @
-- foldr f z xs = foldl (flip f) z (reverse xs)
-- foldl f z xs = foldr (flip f) z (reverse xs)
-- @
--
-- More generally:
--
-- @
-- foldr f z xs = foldl g id xs z where g k x = k . f x
-- foldl f z xs = foldr g id xs z where g x k = k . flip f x
-- @
--

-- NOTE: Folds are inherently serial as each step needs to use the result of
-- the previous step. However, it is possible to fold parts of the stream in
-- parallel and then combine the results using a monoid.

    -- ** Primitives
    -- Consuming a part of the stream and returning the rest. Functions
    -- ending in the general shape @Stream m a -> m (b, Stream m a)@
    , uncons

    -- ** Strict Left Folds
    -- XXX Need to have a general parse operation here which can be used to
    -- express all others.
    , fold -- XXX rename to run? We can have a Stream.run and Fold.run.
    -- XXX fold1 can be achieved using Monoids or Refolds.
    -- XXX We can call this just "break" and parseBreak as "munch"
    , foldBreak

    -- XXX should we have a Fold returning function in stream module?
    -- , foldAdd
    -- , buildl

    -- ** Parsing
    , parse
    -- , parseBreak

    -- ** Lazy Right Folds
    -- | Consuming a stream to build a right associated expression, suitable
    -- for lazy evaluation. Evaluation of the input happens when the output of
    -- the fold is evaluated, the fold output is a lazy thunk.
    --
    -- This is suitable for stream transformation operations, for example,
    -- operations like mapping a function over the stream.
    , foldrM
    , foldr
    -- foldr1

    -- ** Specific Folds
    -- | Streams are folded using folds in "Streamly.Data.Fold". Here are some
    -- idioms and equivalents of Data.List APIs using folds:
    --
    -- >>> foldlM' f a = Stream.fold (Fold.foldlM' f a)
    -- >>> foldl1' f = Stream.fold (Fold.foldl1' f)
    -- >>> foldl' f a = Stream.fold (Fold.foldl' f a)
    -- >>> drain = Stream.fold Fold.drain
    -- >>> mapM_ f = Stream.fold (Fold.drainMapM f)
    -- >>> length = Stream.fold Fold.length
    -- >>> genericLength = Stream.fold Fold.genericLength
    -- >>> head = Stream.fold Fold.one
    -- >>> last = Stream.fold Fold.latest
    -- >>> null = Stream.fold Fold.null
    -- >>> and = Stream.fold Fold.and
    -- >>> or = Stream.fold Fold.or
    -- >>> any p = Stream.fold (Fold.any p)
    -- >>> all p = Stream.fold (Fold.all p)
    -- >>> sum = Stream.fold Fold.sum
    -- >>> product = Stream.fold Fold.product
    -- >>> maximum = Stream.fold Fold.maximum
    -- >>> maximumBy cmp = Stream.fold (Fold.maximumBy cmp)
    -- >>> minimum = Stream.fold Fold.minimum
    -- >>> minimumBy cmp = Stream.fold (Fold.minimumBy cmp)
    -- >>> elem x = Stream.fold (Fold.elem x)
    -- >>> notElem x = Stream.fold (Fold.notElem x)
    -- >>> lookup x = Stream.fold (Fold.lookup x)
    -- >>> find p = Stream.fold (Fold.find p)
    -- >>> (!?) i = Stream.fold (Fold.index i)
    -- >>> genericIndex i = Stream.fold (Fold.genericIndex i)
    -- >>> elemIndex x = Stream.fold (Fold.elemIndex x)
    -- >>> findIndex p = Stream.fold (Fold.findIndex p)
    --
    -- Some equivalents of Data.List APIs from the Stream module:
    --
    -- >>> head = fmap (fmap fst) . Stream.uncons
    -- >>> tail = fmap (fmap snd) . Stream.uncons
    -- >>> tail = Stream.tail -- unreleased API
    -- >>> init = Stream.init -- unreleased API
    --
    -- A Stream based toList fold implementation is provided below because it
    -- has a better performance compared to the fold.

    -- Functions in Data.List, missing here:
    -- unsnoc = Stream.parseBreak (Parser.init Fold.toList)
    -- genericTake
    -- genericDrop
    -- genericSplitAt
    -- genericReplicate
    , toList

    -- * Mapping
    -- | Stateless one-to-one transformations. Use 'fmap' for mapping a pure
    -- function on a stream.

    -- EXPLANATION:
    -- In imperative terms a map operation can be considered as a loop over
    -- the stream that transforms the stream into another stream by performing
    -- an operation on each element of the stream.
    --
    -- 'map' is the least powerful transformation operation with strictest
    -- guarantees.  A map, (1) is a stateless loop which means that no state is
    -- allowed to be carried from one iteration to another, therefore,
    -- operations on different elements are guaranteed to not affect each
    -- other, (2) is a strictly one-to-one transformation of stream elements
    -- which means it guarantees that no elements can be added or removed from
    -- the stream, it can merely transform them.
    , sequence
    , mapM
    , trace
    , tap
    , delay

    -- * Scanning
    -- | Stateful one-to-one transformations.
    --

    {-
    -- ** Left scans
    -- | We can perform scans using folds with the 'scan' combinator in the
    -- next section. However, the combinators supplied in this section are
    -- better amenable to stream fusion when combined with other operations.
    -- Note that 'postscan' using folds fuses well and does not require custom
    -- combinators like these.
    , scanl'
    , scanlM'
    , scanl1'
    , scanl1M'
    -}

    -- ** Scanning By 'Fold'
    -- | Useful idioms:
    --
    -- >>> scanl' f z = Stream.scan (Fold.foldl' f z)
    -- >>> scanlM' f z = Stream.scan (Fold.foldlM' f z)
    -- >>> postscanl' f z = Stream.postscan (Fold.foldl' f z)
    -- >>> postscanlM' f z = Stream.postscan (Fold.foldlM' f z)
    -- >>> scanl1' f = Stream.catMaybes . Stream.scan (Fold.foldl1' f)
    -- >>> scanl1M' f = Stream.catMaybes . Stream.scan (Fold.foldl1M' f)
    , scan
    , postscan
    -- XXX postscan1 can be implemented using Monoids or Refolds.
    -- The following scans from Data.List are not provided.
    -- XXX scanl
    -- XXX scanl1
    -- XXX scanr
    -- XXX scanr1
    -- XXX mapAccumL
    -- XXX mapAccumR
    -- XXX inits
    -- XXX tails

    -- ** Specific scans
    -- Indexing can be considered as a special type of zipping where we zip a
    -- stream with an index stream.
    , indexed

    -- * Insertion
    -- | Add elements to the stream.
    --
    -- >>> insert = Stream.insertBy compare

    -- Inserting elements is a special case of interleaving/merging streams.
    , insertBy
    , intersperseM
    , intersperseM_
    , intersperse

    -- * Filtering
    -- | Remove elements from the stream.

    -- ** Stateless Filters
    -- | 'mapMaybeM' is the most general stateless filtering operation. All
    -- other filtering operations can be expressed using it.

    -- EXPLANATION:
    -- In imperative terms a filter over a stream corresponds to a loop with a
    -- @continue@ clause for the cases when the predicate fails.

    , mapMaybe
    , mapMaybeM
    , filter
    , filterM

    -- Filter and concat
    , catMaybes
    , catLefts
    , catRights
    , catEithers

    -- ** Stateful Filters
    -- | 'scanMaybe' is the most general stateful filtering operation. The
    -- filtering folds (folds returning a 'Maybe' type) in
    -- "Streamly.Internal.Data.Fold" can be used along with 'scanMaybe' to
    -- perform stateful filtering operations in general.
    --
    -- Idioms and equivalents of Data.List APIs:
    --
    -- >>> deleteBy cmp x = Stream.scanMaybe (Fold.deleteBy cmp x)
    -- >>> deleteBy = Stream.deleteBy -- unreleased API
    -- >>> delete = deleteBy (==)
    -- >>> findIndices p = Stream.scanMaybe (Fold.findIndices p)
    -- >>> elemIndices a = findIndices (== a)
    -- >>> uniq = Stream.scanMaybe (Fold.uniqBy (==))
    -- >>> partition p = Stream.fold (Fold.partition Fold.toList Fold.toList) . fmap (if p then Left else Right)
    , scanMaybe
    , take
    , takeWhile
    , takeWhileM
    , drop
    , dropWhile
    , dropWhileM
    -- XXX write to an array in reverse and then read in reverse
    -- > dropWhileEnd = reverse . dropWhile p . reverse

    -- XXX These are available as scans in folds. We need to check the
    -- performance though. If these are common and we need convenient stream
    -- ops then we can expose these.

    -- , deleteBy
    -- , uniq
    -- , uniqBy

    -- -- ** Sampling
    -- , strideFromThen

    -- -- ** Searching
    -- Finding the presence or location of an element, a sequence of elements
    -- or another stream within a stream.

    -- -- ** Searching Elements
    -- , findIndices
    -- , elemIndices

    -- * Combining Two Streams
    -- | Note that these operations are suitable for statically fusing a few
    -- streams, they have a quadratic O(n^2) time complexity wrt to the number
    -- of streams. If you want to compose many streams dynamically using binary
    -- combining operations see the corresponding operations in
    -- "Streamly.Data.StreamK".
    --
    -- When fusing more than two streams it is more efficient if the binary
    -- operations are composed as a balanced tree rather than a right
    -- associative or left associative one e.g.:
    --
    -- >>> s1 = Stream.fromList [1,2] `Stream.append` Stream.fromList [3,4]
    -- >>> s2 = Stream.fromList [4,5] `Stream.append` Stream.fromList [6,7]
    -- >>> s = s1 `Stream.append` s2

    -- ** Appending
    -- | Equivalent of Data.List append:
    --
    -- >>> (++) = Stream.append
    , append

    -- ** Interleaving
    , interleave

    -- ** Merging
    , mergeBy
    , mergeByM

    -- ** Zipping
    -- | Idioms and equivalents of Data.List APIs:
    --
    -- >>> zip = Stream.zipWith (,)
    -- >>> unzip = Stream.fold (Fold.unzip Fold.toList Fold.toList)
    , zipWith
    , zipWithM
    -- XXX zipWith3,4,5,6,7
    -- XXX unzip3,4,5,6,7
    -- , ZipStream (..)

    -- ** Cross Product
    -- XXX The argument order in this operation is such that it seems we are
    -- transforming the first stream using the second stream because the second
    -- stream is evaluated many times or buffered and better be finite, first
    -- stream could potentially be infinite. In the tradition of using the
    -- transformed stream at the end we can have a flipped version called
    -- "crossMap" or "nestWith".
    , crossWith
    -- , cross
    -- , joinInner
    -- , CrossStream (..)

    -- * Unfold Each
    -- Idioms and equivalents of Data.List APIs:
    --
    -- >>> cycle = Stream.unfoldMany Unfold.fromList . Stream.repeat
    -- >>> unlines = Stream.interposeSuffix '\n'
    -- >>> unwords = Stream.interpose ' '
    -- >>> unlines = Stream.intercalateSuffix Unfold.fromList "\n"
    -- >>> unwords = Stream.intercalate Unfold.fromList " "
    --
    , unfoldMany
    , intercalate
    , intercalateSuffix

    -- * Stream of streams
    -- | Stream operations like map and filter represent loops in
    -- imperative programming terms. Similarly, the imperative concept of
    -- nested loops are represented by streams of streams. The 'concatMap'
    -- operation represents nested looping.
    --
    -- A 'concatMap' operation loops over the input stream (outer loop),
    -- generating a stream from each element of the stream. Then it loops over
    -- each element of the generated streams (inner loop), collecting them in a
    -- single output stream.
    --
    -- One dimension loops are just a special case of nested loops.  For
    -- example map and filter can be expressed using concatMap:
    --
    -- >>> map f = Stream.concatMap (Stream.fromPure . f)
    -- >>> filter p = Stream.concatMap (\x -> if p x then Stream.fromPure x else Stream.nil)
    --
    -- Idioms and equivalents of Data.List APIs:
    --
    -- >>> concat = Stream.concatMap id
    -- >>> cycle = Stream.concatMap Stream.fromList . Stream.repeat

    , concatEffect
    , concatMap
    , concatMapM

    -- * Repeated Fold
    -- | Idioms and equivalents of Data.List APIs:
    --
    -- >>> groupsOf n = Stream.foldMany (Fold.take n Fold.toList)
    -- >>> groupBy eq = Stream.groupsWhile eq Fold.toList
    -- >>> groupBy eq = Stream.parseMany (Parser.groupBy eq Fold.toList)
    -- >>> groupsByRolling eq = Stream.parseMany (Parser.groupByRolling eq Fold.toList)
    -- >>> groups = groupBy (==)
    , foldMany -- XXX Rename to foldRepeat
    , groupsOf
    , parseMany

    -- * Splitting
    -- | Idioms and equivalents of Data.List APIs:
    --
    -- >>> splitWithSuffix p f = Stream.foldMany (Fold.takeEndBy p f)
    -- >>> splitOnSuffix p f = Stream.foldMany (Fold.takeEndBy_ p f)
    -- >>> lines = splitOnSuffix (== '\n')
    -- >>> words = Stream.wordsBy isSpace
    -- >>> splitAt n = Stream.fold (Fold.splitAt n Fold.toList Fold.toList)
    -- >>> span p = Parser.splitWith (,) (Parser.takeWhile p Fold.toList) (Parser.fromFold Fold.toList)
    -- >>> break p = span (not . p)
    , splitOn
    , wordsBy

    -- * Buffered Operations
    -- | Operations that require buffering of the stream.
    -- Reverse is essentially a left fold followed by an unfold.
    --
    -- Idioms and equivalents of Data.List APIs:
    --
    -- >>> nub = Stream.fold Fold.toList . Stream.scanMaybe Fold.nub
    -- >>> nub = Stream.ordNub -- unreleased API
    -- >>> sortBy = StreamK.sortBy
    -- >>> sortOn f = StreamK.sortOn -- unreleased API
    -- >>> deleteFirstsBy = Stream.deleteFirstsBy -- unreleased
    -- >>> (\\) = Stream.deleteFirstsBy (==) -- unreleased
    -- >>> intersectBy = Stream.intersectBy -- unreleased
    -- >>> intersect = Stream.intersectBy (==) -- unreleased
    -- >>> unionBy = Stream.unionBy -- unreleased
    -- >>> union = Stream.unionBy (==) -- unreleased
    --
    , reverse
    -- XXX transpose: write the streams to arrays and then stream transposed.
    -- XXX subsequences
    -- XXX permutations
    -- , nub
    -- , ordNub
    -- , nubBy

    -- * Multi-Stream folds
    -- | Operations that consume multiple streams at the same time.
    , eqBy
    , cmpBy
    , isPrefixOf
    , isInfixOf
    -- , isSuffixOf
    -- , isSuffixOfUnbox
    , isSubsequenceOf

    -- trimming sequences
    -- , stripPrefix
    -- , stripSuffix
    -- , stripSuffixUnbox

    -- Exceptions and resource management depend on the "exceptions" package
    -- XXX We can have IO Stream operations not depending on "exceptions"
    -- in Exception.Base

    -- * Exceptions
    -- | Note that the stream exception handling routines catch and handle
    -- exceptions only in the stream generation steps and not in the consumer
    -- of the stream. For example, if we are folding or parsing a stream - any
    -- exceptions in the fold or parse steps won't be observed by the stream
    -- exception handlers. Exceptions in the fold or parse steps can be handled
    -- using the fold or parse exception handling routines. You can wrap the
    -- stream elimination function in the monad exception handler to observe
    -- exceptions in the stream as well as the consumer.
    --
    -- Most of these combinators inhibit stream fusion, therefore, when
    -- possible, they should be called in an outer loop to mitigate the cost.
    -- For example, instead of calling them on a stream of chars call them on a
    -- stream of arrays before flattening it to a stream of chars.
    --
    , onException
    , handle

    -- * Resource Management
    -- | 'bracket' is the most general resource management operation, all other
    -- operations can be expressed using it. These functions have IO suffix
    -- because the allocation and cleanup functions are IO actions. For
    -- generalized allocation and cleanup functions, see the functions without
    -- the IO suffix in the "streamly" package.
    --
    -- Note that these operations bracket the stream generation only, they do
    -- not cover the stream consumer. This means if an exception occurs in
    -- the consumer of the stream (e.g. in a fold or parse step) then the
    -- exception won't be observed by the stream resource handlers, in that
    -- case the resource cleanup handler runs when the stream is garbage
    -- collected.
    --
    -- Monad level resource management can always be used around the stream
    -- elimination functions, such a function can observe exceptions in both
    -- the stream and its consumer.
    , before
    , afterIO
    , finallyIO
    , bracketIO
    , bracketIO3

    -- * Transforming Inner Monad

    , morphInner
    , liftInner
    , runReaderT
    , runStateT

    -- XXX Arrays could be different types, therefore, this should be in
    -- specific array module. Or maybe we should abstract over array types.
    -- * Stream of Arrays
    , Array.chunksOf
    )
where

import Streamly.Internal.Data.Stream
import Prelude
       hiding (filter, drop, dropWhile, take, takeWhile, zipWith, foldr,
               mapM, sequence, reverse, iterate, foldr1, repeat, replicate,
               concatMap)

import qualified Streamly.Internal.Data.Array.Type as Array

#include "DocTestDataStream.hs"
