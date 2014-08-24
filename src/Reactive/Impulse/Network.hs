
{-# OPTIONS_GHC -Wall #-}
module Reactive.Impulse.Network (
  Network (..)
, compileNetwork
) where

import Reactive.Impulse.Core
import Reactive.Impulse.Internal.Types
import Reactive.Impulse.Internal.Chain
import Reactive.Impulse.Internal.Graph

import Control.Lens
import Control.Monad.RWS
import Control.Monad.State
import Control.Concurrent.STM
import Control.Concurrent.MVar

-----------------------------------------------------------
-- Network, starting/stopping.

-- TODO: should begin paused, then we can start running the network separately
compileNetwork :: SGen a -> IO (a,Network)
compileNetwork net = do
    (a,sgstate) <- runStateT net mempty
    _nInputs <- compileHeadMap sgstate
    _nActions <- newTVarIO (return ())
    _nLock    <- newMVar ()
    runningGraph <- initialRunningDynGraph
    let network = Network _nInputs runningGraph _nActions _nLock
        builder = do
            buildTopChains (sgstate^.outputs)
            tell (sgstate^.sgDirtyLog)
    atomically $ do
        initialActions <- dynUpdateGraph network builder
        writeTVar _nActions initialActions
    return (a, network)
