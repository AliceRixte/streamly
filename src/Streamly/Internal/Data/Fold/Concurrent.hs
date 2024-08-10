-- |
-- Module      : Streamly.Internal.Data.Fold.Concurrent
-- Copyright   : (c) 2022 Composewell Technologies
-- License     : BSD-3-Clause
-- Maintainer  : streamly@composewell.com
-- Stability   : experimental
-- Portability : GHC
--
-- = Asynchronous Evaluation
--
-- Using 'parEval' a fold can be decoupled from the driver and evaluated
-- concurrently with the driver. The driver just pushes an element to the
-- fold's buffer and waits for async evaluation to finish.
--
-- Stages in a fold pipeline can be made concurrent using 'parEval'.
--
-- = Concurrent Fold Combinators
--
-- The 'demux' combinator can be made concurrent by using 'parEval' on the fold
-- returned by the fold-generating function. Thus, we can fold values for each
-- key in the input stream concurrently.
--
-- Similarly, we can use 'parEval' with other cobminators like 'toMap',
-- 'demuxToMap', 'classify', 'tee', 'distribute', 'partition' etc. Basically,
-- any combinator that composes multiple folds or multiple instances of a fold
-- is a good candidate for running folds concurrently.
--
-- = Finalization
--
-- Before a fold returns "done" it has to drain the child folds. For example,
-- consider a "take" operation on a `parEval` fold, the take should return as
-- soon as it has taken required number of elements but we have to ensure that
-- any asynchronous child folds finish before it returns. This is achieved by
-- calling the "final" operation of the fold.

-- = TODO
--
-- Use multiple worker folds to fold serial chunks of a stream and collect the
-- results using another fold, combine using a monoid. The results can be
-- collected out-of-order or in-order. This would be easier if each input
-- element is a streamable chunk and each fold consumes one chunk at a time.
-- This is like parConcatMap in streams.
--
-- Concurrent append: if one fold's buffer becomes full then use the next one
-- Concurrent interleave/partition: Round robin to n folds.
-- Concurrent distribute to multiple folds.

module Streamly.Internal.Data.Fold.Concurrent
    (
      parEval
    , parLmapM
    , parTeeWith
    , parDistribute
    , parPartition
    , parUnzipWithM
    )
where

import Control.Concurrent (takeMVar)
import Control.Monad (void, when)
import Control.Monad.IO.Class (MonadIO(liftIO))
import Data.IORef (writeIORef)
import Streamly.Internal.Control.Concurrent (MonadAsync)
import Streamly.Internal.Data.Fold (Fold(..), Step (..))
import Streamly.Internal.Data.Channel.Worker (sendEvent)
import Streamly.Internal.Data.Time.Clock (Clock(Monotonic), getTime)

import qualified Streamly.Internal.Data.Fold as Fold

import Streamly.Internal.Data.Fold.Channel.Type
import Streamly.Internal.Data.Channel.Types

-------------------------------------------------------------------------------
-- Evaluating a Fold
-------------------------------------------------------------------------------

-- XXX Cleanup the fold if the stream is interrupted. Add a GC hook.

-- | 'parEval' introduces a concurrent stage at the input of the fold. The
-- inputs are asynchronously queued in a buffer and evaluated concurrently with
-- the evaluation of the source stream. On finalization, 'parEval' waits for
-- the asynchronous fold to complete before it returns.
--
-- In the following example both the stream and the fold have a 1 second delay,
-- but the delay is not compounded because both run concurrently.
--
-- >>> delay x = threadDelay 1000000 >> print x >> return x
--
-- >>> src = Stream.delay 1 (Stream.enumerateFromTo 1 3)
-- >>> dst = Fold.parEval id (Fold.lmapM delay Fold.sum)
-- >>> Stream.fold dst src
-- ...
--
-- Another example:
--
-- >>> Stream.toList $ Stream.groupsOf 4 dst src
-- ...
--
{-# INLINABLE parEval #-}
parEval :: MonadAsync m => (Config -> Config) -> Fold m a b -> Fold m a b
parEval modifier f =
    Fold step initial extract final

    where

    -- XXX Supply an output channel to the fold. The fold would send the result
    -- from each step (i.e. scan result) to the channel. The Partial and Done
    -- constructors are sent to the channel. We then draw the resulting stream
    -- from that channel. Kind of concurrrent mapping on the stream but with a
    -- fold/scan.
    --
    -- There can also be a model where multiple folds pick input from the same
    -- channel.
    --
    -- We can also run parsers this way. So instead of sending output on each
    -- step it can send once it is done.
    initial = Partial <$> newChannel modifier f

    -- XXX This is not truly asynchronous. If the fold is done we only get to
    -- know when we send the next input unless the stream ends. We could
    -- potentially throw an async exception to the driver to inform it
    -- asynchronously. Alternatively, the stream should not block forever, it
    -- should keep polling the fold status. We can insert a timer tick in the
    -- input stream to do that.
    --
    -- A polled stream abstraction may be useful, it would consist of normal
    -- events and tick events, latter are guaranteed to arrive.
    --
    -- XXX We can use the config to indicate if the fold is a scanning type or
    -- one-shot, or use a separate parEvalScan for scanning. For a scanning
    -- type fold the worker would always send the intermediate values back to
    -- the driver. An intermediate value can be returned on an input, or the
    -- driver can poll even without input, if we have the Skip input support.
    -- When the buffer is full we can return "Skip" and then the next step
    -- without input can wait for an output to arrive. Similarly, when "final"
    -- is called it can return "Skip" to continue or "Done" to indicate
    -- termination.
    step chan a = do
        status <- sendToWorker chan a
        return $ case status of
            Nothing -> Partial chan
            Just b -> Done b

    extract _ = error "Concurrent folds do not support scanning"

    -- XXX depending on the use case we may want to either wait for the result
    -- or cancel the ongoing work. We can use the config to control that?
    -- Currently it waits for the work to complete.
    final chan = do
        liftIO $ void
            $ sendEvent
                (inputQueue chan)
                (inputItemDoorBell chan)
                ChildStopChannel
        status <- checkFoldStatus chan
        case status of
            Nothing -> do
                liftIO
                    $ withDiagMVar
                        (svarInspectMode chan)
                        (dumpChannel chan)
                        "parEval: waiting to drain"
                    $ takeMVar (outputDoorBell chan)
                -- XXX remove recursion
                final chan
            Just b -> do
                when (svarInspectMode chan) $ liftIO $ do
                    t <- getTime Monotonic
                    writeIORef (svarStopTime (svarStats chan)) (Just t)
                    printSVar (dumpChannel chan) "SVar Done"
                return b

-- XXX We can have a lconcatMap (unfoldMany) to expand the chunks in the input
-- to streams before folding. This will require an input Skip constructor. In
-- fact, parLmapM can be implemented in terms of this like in streams.

-- | Evaluate the mapped actions concurrently with respect to each other. The
-- results may be unordered or ordered depending on the configuration.
--
-- /Unimplemented/
{-# INLINABLE parLmapM #-}
parLmapM :: -- MonadAsync m =>
    (Config -> Config) -> (a -> m b) -> Fold m b r -> Fold m a r
parLmapM = undefined

-- | Execute both the folds in a tee concurrently.
--
-- Definition:
--
-- >>> parTeeWith cfg f c1 c2 = Fold.teeWith f (Fold.parEval cfg c1) (Fold.parEval cfg c2)
--
-- Example:
--
-- >>> delay x = threadDelay 1000000 >> print x >> return x
-- >>> c1 = Fold.lmapM delay Fold.sum
-- >>> c2 = Fold.lmapM delay Fold.length
-- >>> dst = Fold.parTeeWith id (,) c1 c2
-- >>> Stream.fold dst src
-- ...
--
{-# INLINABLE parTeeWith #-}
parTeeWith :: MonadAsync m =>
       (Config -> Config)
    -> (a -> b -> c)
    -> Fold m x a
    -> Fold m x b
    -> Fold m x c
parTeeWith cfg f c1 c2 = Fold.teeWith f (parEval cfg c1) (parEval cfg c2)

-- | Distribute the input to all the folds in the supplied list concurrently.
--
-- Definition:
--
-- >>> parDistribute cfg = Fold.distribute . fmap (Fold.parEval cfg)
--
-- Example:
--
-- >>> delay x = threadDelay 1000000 >> print x >> return x
-- >>> c = Fold.lmapM delay Fold.sum
-- >>> dst = Fold.parDistribute id [c,c,c]
-- >>> Stream.fold dst src
-- ...
--
{-# INLINABLE parDistribute #-}
parDistribute :: MonadAsync m =>
    (Config -> Config) -> [Fold m a b] -> Fold m a [b]
parDistribute cfg = Fold.distribute . fmap (parEval cfg)

-- | Select first fold for Left input and second for Right input. Both folds
-- run concurrently.
--
-- Definition
--
-- >>> parPartition cfg c1 c2 = Fold.partition (Fold.parEval cfg c1) (Fold.parEval cfg c2)
--
-- Example:
--
-- >>> delay x = threadDelay 1000000 >> print x >> return x
-- >>> c1 = Fold.lmapM delay Fold.sum
-- >>> c2 = Fold.lmapM delay Fold.sum
-- >>> dst = Fold.parPartition id c1 c2
-- >>> Stream.fold dst $ (fmap (\x -> if even x then Left x else Right x)) src
-- ...
--
{-# INLINABLE parPartition #-}
parPartition :: MonadAsync m =>
    (Config -> Config) -> Fold m b x -> Fold m c y -> Fold m (Either b c) (x, y)
parPartition cfg c1 c2 = Fold.partition (parEval cfg c1) (parEval cfg c2)

-- | Split and distribute the output to two different folds and then zip the
-- results. Both the consumer folds run concurrently.
--
-- Definition
--
-- >>> parUnzipWithM cfg f c1 c2 = Fold.unzipWithM f (Fold.parEval cfg c1) (Fold.parEval cfg c2)
--
-- Example:
--
-- >>> delay x = threadDelay 1000000 >> print x >> return x
-- >>> c1 = Fold.lmapM delay Fold.sum
-- >>> c2 = Fold.lmapM delay Fold.sum
-- >>> dst = Fold.parUnzipWithM id (pure . id) c1 c2
-- >>> Stream.fold dst $ (fmap (\x -> (x, x* x))) src
-- ...
--
{-# INLINABLE parUnzipWithM #-}
parUnzipWithM :: MonadAsync m
    => (Config -> Config) -> (a -> m (b,c)) -> Fold m b x -> Fold m c y -> Fold m a (x,y)
parUnzipWithM cfg f c1 c2 = Fold.unzipWithM f (parEval cfg c1) (parEval cfg c2)
