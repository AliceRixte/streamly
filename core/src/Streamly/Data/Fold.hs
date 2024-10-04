{-# LANGUAGE CPP #-}
-- |
-- Module      : Streamly.Data.Fold
-- Copyright   : (c) 2019 Composewell Technologies
-- License     : BSD-3-Clause
-- Maintainer  : streamly@composewell.com
-- Stability   : released
-- Portability : GHC
--
-- The 'Fold' type represents a consumer of a sequence of values, the
-- corresponding dual type is 'Streamly.Data.Stream.Stream' which represents a
-- producer. Both types can perform equivalent transformations on a stream. But
-- only 'Fold' can be used to compose multiple consumers and only 'Stream' can
-- be used to compose multiple producers.
--
-- The 'Fold' type represents stream consumers as state machines, that fuse
-- together when composed statically, eliminating function calls or
-- intermediate constructor allocations. Stream fusion helps generate tight,
-- efficient loops similar to the code generated by low-level languages like C.
-- Folds are suitable for high-performance looping operations.
--
-- Operations in this module are designed to be composed statically rather than
-- dynamically. They are inlined to enable static fusion. More importantly,
-- they are not designed to be used recursively. Recursive use will break
-- fusion and will lead to quadratic performance slowdown. For dynamic or
-- recursive composition use the continuation passing style (CPS) operations
-- from the "Streamly.Data.ParserK" module. 'Fold' and
-- 'Streamly.Data.ParserK.ParserK' types are interconvertible via the
-- 'Streamly.Data.Parser.Parser' type.
--
-- == Using Folds
--
-- This module provides elementary folds and fold combinators that can be used
-- to consume a stream of data and reduce it to a final value, or transform it
-- in a stateful manner using scans. A data stream can be reduced into a stream
-- of folded data elements by folding segments of the stream. Fold combinators
-- can be used to compose multiple folds in parallel or to create a pipeline of
-- folds such that the next fold consumes the result of the previous fold. To
-- run these folds on a stream see 'Streamly.Data.Stream.fold',
-- 'Streamly.Data.Stream.scan', 'Streamly.Data.Stream.postscan',
-- 'Streamly.Data.Stream.scanMaybe', 'Streamly.Data.Stream.foldMany' and other
-- operations accepting 'Fold' type as argument "Streamly.Data.Stream".
--
-- == Reducing a Stream
--
-- A 'Fold' is a consumer of a stream of values. A fold driver (such as
-- 'Streamly.Data.Stream.fold') initializes the fold @accumulator@, runs the
-- fold @step@ function in a loop, processing the input stream one element at a
-- time and accumulating the result. The loop continues until the fold
-- terminates, at which point the accumulated result is returned.
--
-- For example, a 'sum' Fold represents a stream consumer that adds the values
-- in the input stream:
--
-- >>> Stream.fold Fold.sum $ Stream.fromList [1..100]
-- 5050
--
-- Conceptually, a 'Fold' is a data type that mimics a strict left fold
-- ('Data.List.foldl').  The above example is similar to a left fold using
-- @(+)@ as the step and @0@ as the initial value of the accumulator:
--
-- >>> Data.List.foldl' (+) 0 [1..100]
-- 5050
--
-- 'Fold's have an early termination capability e.g. the 'one' fold terminates
-- after consuming one element:
--
-- >>> Stream.fold Fold.one $ Stream.fromList [1..]
-- Just 1
--
-- The above example is similar to the following right fold:
--
-- >>> Prelude.foldr (\x _ -> Just x) Nothing [1..]
-- Just 1
--
-- 'Fold's can be combined together using combinators. For example, to create a
-- fold that sums first two elements in a stream:
--
-- >>> sumTwo = Fold.take 2 Fold.sum
-- >>> Stream.fold sumTwo $ Stream.fromList [1..100]
-- 3
--
-- == Parallel Composition
--
-- Folds can be combined to run in parallel on the same input. For example, to
-- compute the average of numbers in a stream without going through the stream
-- twice:
--
-- >>> avg = Fold.teeWith (/) Fold.sum (fmap fromIntegral Fold.length)
-- >>> Stream.fold avg $ Stream.fromList [1.0..100.0]
-- 50.5
--
-- Folds can be combined so as to partition the input stream over multiple
-- folds. For example, to count even and odd numbers in a stream:
--
-- >>> split n = if even n then Left n else Right n
-- >>> stream = fmap split $ Stream.fromList [1..100]
-- >>> countEven = fmap (("Even " ++) . show) Fold.length
-- >>> countOdd = fmap (("Odd "  ++) . show) Fold.length
-- >>> f = Fold.partition countEven countOdd
-- >>> Stream.fold f stream
-- ("Even 50","Odd 50")
--
-- == Sequential Composition
--
-- Terminating folds can be combined to parse the stream serially such that the
-- first fold consumes the input until it terminates and the second fold
-- consumes the rest of the input until it terminates:
--
-- >>> f = Fold.splitWith (,) (Fold.take 8 Fold.toList) (Fold.takeEndBy (== '\n') Fold.toList)
-- >>> Stream.fold f $ Stream.fromList "header: hello\n"
-- ("header: ","hello\n")
--
-- == Splitting a Stream
--
-- A 'Fold' can be applied repeatedly on a stream to transform it to a stream
-- of fold results. To split a stream on newlines:
--
-- >>> f = Fold.takeEndBy (== '\n') Fold.toList
-- >>> Stream.fold Fold.toList $ Stream.foldMany f $ Stream.fromList "Hello there!\nHow are you\n"
-- ["Hello there!\n","How are you\n"]
--
-- Similarly, we can split the input of a fold too:
--
-- >>> Stream.fold (Fold.many f Fold.toList) $ Stream.fromList "Hello there!\nHow are you\n"
-- ["Hello there!\n","How are you\n"]
--
-- == Folds vs. Streams
--
-- We can often use streams or folds to achieve the same goal. However, streams
-- are required for composition of producers (e.g.
-- 'Data.Stream.append' or 'Data.Stream.mergeBy') whereas folds are
-- required for composition of consumers (e.g.  'splitWith', 'partition'
-- or 'teeWith').
--
-- Streams are producers, transformations on streams happen on the output side:
--
-- >>> :{
--  f stream =
--        Stream.filter odd stream
--      & fmap (+1)
--      & Stream.fold Fold.sum
-- :}
--
-- >>> f $ Stream.fromList [1..100 :: Int]
-- 2550
--
-- Folds are stream consumers with an input stream and an output value, stream
-- transformations on folds happen on the input side:
--
-- >>> :{
-- f =
--        Fold.filter odd
--      $ Fold.lmap (+1)
--      $ Fold.sum
-- :}
--
-- >>> Stream.fold f $ Stream.fromList [1..100 :: Int]
-- 2550
--
-- Notice the similiarity in the definition of @f@ in both cases, the only
-- difference is the composition by @&@ vs @$@ and the use @lmap@ vs @map@, the
-- difference is due to output vs input side transformations.
--
-- == Experimental APIs
--
-- Please refer to "Streamly.Internal.Data.Fold" for more functions that have
-- not yet been released.

module Streamly.Data.Fold
    (
    -- * Setup
    -- | To execute the code examples provided in this module in ghci, please
    -- run the following commands first.
    --
    -- $setup

    -- * Fold Type

      Fold -- (..)
    , Tee (..)

    -- * Running A Fold
    -- | 'Streamly.Data.Strem.fold' and 'drive' are the basic fold runners.
    -- Folds can also be used a incremental builders. The 'addOne' and
    -- 'addStream' combinators can be used to incrementally build any type of
    -- structure using a fold, including arrays or a stream of arrays.

    , drive
    -- XXX should rename to "extract". can use "Fold.drive Stream.nil" instead,
    -- for now.
    -- , extractM
    -- , reduce
    , addOne
    -- , snocl
    -- XXX Can we use something like concatEffect to implement snocM?
    -- , snocM
    -- , snoclM
    , addStream
    , duplicate
    -- , isClosed

    -- * Constructors
    , foldl'
    , foldlM'
    , foldl1'
    , foldl1M'
    , foldr'
    , foldtM'

    -- * Folds
    -- ** Accumulators
    -- | Folds that never terminate, these folds are much like strict left
    -- folds. 'mconcat' is the fundamental accumulator.  All other accumulators
    -- can be expressed in terms of 'mconcat' using a suitable Monoid.  Instead
    -- of writing folds we could write Monoids and turn them into folds.

    -- Monoids
    , sconcat
    , mconcat
    , foldMap
    , foldMapM

    -- Reducers
    , drain
    , drainMapM
    , length
    , countDistinct
    , countDistinctInt
    , frequency
    , sum
    , product
    , mean
    , rollingHash
    , rollingHashWithSalt

    -- Collectors
    , toList
    , toListRev
    , toSet
    , toIntSet
    , topBy

    -- ** Non-Empty Accumulators
    -- | Accumulators that do not have a default value, therefore, return
    -- 'Nothing' on an empty stream.
    , latest
    , maximumBy
    , maximum
    , minimumBy
    , minimum

    -- ** Filtering Scanners
    -- | Accumulators that are usually run as a scan using the 'scanMaybe'
    -- combinator.
    , findIndices
    , elemIndices
    , deleteBy
    -- , uniq
    , uniqBy
    , nub
    , nubInt

    -- ** Terminating Folds
    , one
    , null
    -- , satisfy
    -- , maybe

    , index
    , the
    , find
    , findM
    , lookup
    , findIndex
    , elemIndex
    , elem
    , notElem
    , all
    , any
    , and
    , or

    -- * Transformations
    -- | Transformations are modifiers of folds.  In the type @Fold m a b@, @a@
    -- is the input type and @b@ is the output type.  Transformations can be
    -- applied either on the input side (contravariant) or on the output side
    -- (covariant).  Therefore, transformations have one of the following
    -- general shapes:
    --
    -- * @... -> Fold m a b -> Fold m c b@ (input transformation)
    -- * @... -> Fold m a b -> Fold m a c@ (output transformation)
    --
    -- The input side transformations are more interesting for folds.  Most of
    -- the following sections describe the input transformation operations on a
    -- fold. When an operation makes sense on both input and output side we use
    -- the prefix @l@ (for left) for input side operations and the prefix @r@
    -- (for right) for output side operations.

    -- ** Mapping on output
    -- | The 'Functor' instance of a fold maps on the output of the fold:
    --
    -- >>> Stream.fold (fmap show Fold.sum) (Stream.enumerateFromTo 1 100)
    -- "5050"
    --
    , rmapM

    -- ** Mapping on Input
    , lmap
    , lmapM

    -- ** Filtering
    , filter
    , filterM

    -- -- ** Mapping Filters
    , mapMaybe
    , catMaybes
    , catLefts
    , catRights
    , catEithers

    -- ** Trimming
    , take
    , takeEndBy
    , takeEndBy_
    , takeEndBySeq
    , takeEndBySeq_

    -- ** Key-value Collectors
    , toMap
    , toMapIO

    {-
    -- ** Key-value Scanners
    , classifyScan
    , classifyScanIO
    -}

    -- ** Transforming the Monad
    , morphInner

    -- * Combinators
    -- | Transformations that combine two or more folds.

    -- ** Scanning
    , scanl
    , postscanl
    -- , postscanlMaybe

    -- ** Splitting
    , splitWith
    , many
    , groupsOf

    -- ** Parallel Distribution
    -- | For applicative composition using distribution see
    -- "Streamly.Internal.Data.Fold.Tee".

    , teeWith
    --, teeWithFst
    --, teeWithMin
    , tee
    , distribute

    -- ** Partitioning
    -- | Direct items in the input stream to different folds using a binary
    -- fold selector.

    , partition
    --, partitionByM
    --, partitionByFstM
    --, partitionByMinM
    --, partitionBy

    -- ** Unzipping
    , unzip

    -- * Dynamic Combinators
    -- | The fold to be used is generated dynamically based on the input or
    -- based on the output of the previous fold.

    -- ** Key-value Collectors
    , demuxerToMap
    , demuxerToMapIO

    {-
    -- ** Key-value Scanners
    , demuxScan
    , demuxScanIO
    -}

    -- ** Nesting
    , concatMap

    -- * Deprecated
    , foldlM1'
    , chunksOf
    , foldr
    , drainBy
    , last
    , head
    , sequence
    , mapM
    , variance
    , stdDev
    , serialWith
    , classify
    , classifyIO
    , demux
    , demuxIO
    , demuxToMap
    , demuxToMapIO
    , scan
    , postscan
    , scanMaybe
    )
where

import Prelude
       hiding (Foldable(..), filter, drop, dropWhile, take, takeWhile, zipWith,
               map, mapM_, sequence, all, any,
               notElem, head, last, tail,
               reverse, iterate, init, and, or, lookup, (!!),
               scanl, scanl1, replicate, concatMap, mconcat, unzip,
               span, splitAt, break, mapM, maybe)

import Streamly.Internal.Data.Fold

#include "DocTestDataFold.hs"

--------------------------------------------------------------------------------
-- Deprecated
--------------------------------------------------------------------------------

{-# DEPRECATED chunksOf "Please use 'groupsOf' instead" #-}
{-# INLINE chunksOf #-}
chunksOf :: Monad m => Int -> Fold m a b -> Fold m b c -> Fold m a c
chunksOf = groupsOf
