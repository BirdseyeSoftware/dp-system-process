{-# LANGUAGE ScopedTypeVariables #-}
module Main where

import Control.Monad.Trans (liftIO)
import Control.Concurrent.Async (async, waitCatch)
import System.Process
import Control.Concurrent.MVar

import Network.Transport.Chan
import Control.Distributed.Process.Node
import qualified Control.Distributed.Process as Process

import Data.Conduit (($$), awaitForever)
import Data.Conduit.Binary (sourceHandle)

main :: IO ()
main = do
  transport <- createTransport
  node <- newLocalNode transport initRemoteTable
  resultVar <- newEmptyMVar
  forkProcess node $ do
    pid <- Process.getSelfPid
    childPid <- Process.spawnLocal $ do
      liftIO $ putStrLn "(0)"
      procAsync <- liftIO $ async
                          $ createProcess
                          $ (shell "ls | meh") { std_out = CreatePipe
                                                        , std_err = CreatePipe
                                                        , std_in  = CreatePipe }
      liftIO $ putStrLn "(1)"
      result <- liftIO $ waitCatch procAsync
      liftIO $ putStrLn "(2)"
      case result of
        Right (Just stdin, Just stdout, Just stderr, procHandle) -> do
          liftIO $ waitForProcess procHandle >>= print
          liftIO $ sourceHandle stdout $$ awaitForever (liftIO . print)
          liftIO $ putMVar resultVar True
        Left  _ -> liftIO $ putMVar resultVar False
    Process.link childPid
  isHandled <- takeMVar resultVar
  putStrLn (if isHandled then "succeed" else "error managed")

-- -- WORKS
-- main :: IO ()
-- main = do
--   procAsync <- async $ createProcess (proc "ls" [])
--   result <- waitCatch procAsync
--   case result of
--     Right _ -> putStrLn "success"
--     Left _ -> putStrLn "controled error"
