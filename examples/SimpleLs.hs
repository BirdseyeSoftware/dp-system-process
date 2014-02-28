module Main where

import Control.Monad (forever)
import Control.Monad.Trans (liftIO)

import Control.Concurrent (threadDelay)

import Network.Transport.Chan (createTransport)
import Control.Distributed.Process.Node (runProcess, newLocalNode, initRemoteTable)
import qualified Control.Distributed.Process as Process

import Control.Distributed.Process.SystemProcess as Proc

main :: IO ()
main = do
  transport <- createTransport
  node <- newLocalNode transport initRemoteTable

  runProcess node $ do
    listenerPid <- Process.spawnLocal $ do
      forever $
        -- Listener is going to receive stdout and exit code from process actor
        Process.receiveWait [ Process.matchIf Proc.isExitCode (liftIO . print)
                            , Process.matchIf Proc.isStdOut (liftIO . print) ]

    Proc.runSystemProcess
      (Proc.proc "ls" ["-l", "-a"]) { Proc.std_out = Proc.sendToPid listenerPid
                                    , Proc.exit_code = Proc.sendToPid listenerPid }

    liftIO $ threadDelay 10000
    Process.kill listenerPid "time to die..."
