{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}
module Main where

import qualified Data.ByteString as BS

import Control.Monad (forever, replicateM_)
import Control.Monad.Trans (MonadIO(..))
import Control.Concurrent (threadDelay)
import Control.Concurrent.MVar (MVar)
import qualified Control.Concurrent.MVar as MVar
import Data.Maybe (isJust)
import Network.Transport.Chan (createTransport)
import Control.Distributed.Process.Node (forkProcess, newLocalNode, initRemoteTable)
import qualified Control.Distributed.Process as Process
import System.Timeout (timeout)

import Test.Hspec
import Test.HUnit (assertBool, assertEqual)

import Control.Distributed.Process.SystemProcess

main :: IO ()
main = do
    transport <- createTransport
    node <- newLocalNode transport initRemoteTable
    hspec $ do
      describe "sending input to process" $ do
        it "should work correctly" $ do
              bufferVar <- MVar.newMVar []
              resultVar <- MVar.newEmptyMVar
              _ <- forkProcess node $ do

                let procSpec = proc "cat" []

                    handleStdOut (StdOut bs) = do
                      liftIO $ MVar.modifyMVar_ bufferVar (return . (bs:))

                    handleStdOut (StdErr bs) = do
                      liftIO $ print bs

                    handleExitCode (ExitCode code) =
                      liftIO $ MVar.putMVar resultVar code

                currentPid <- Process.getSelfPid
                listenerPid <- Process.spawnLocal $ do
                    replicateM_ 2 $
                      Process.receiveWait [ Process.matchIf isExitCode handleExitCode
                                          , Process.matchIf (not . isExitCode)
                                                            handleStdOut ]
                processPid <-
                  startSystemProcess $ procSpec { std_err = sendToPid listenerPid
                                                , std_out = sendToPid listenerPid
                                                , exit_code = sendToPid listenerPid }

                writeStdin processPid "hello"
                liftIO $ threadDelay 1000
                closeStdin processPid

              MVar.takeMVar resultVar >>= assertEqual "should have code 0" 0
              MVar.takeMVar bufferVar >>= assertEqual "should echo input" ["hello"]

      describe "using shell constructor" $ do
        describe "system process that exists" $ do

          describe "when it fails" $
            it "returns appropiate exit code" $ do
              resultVar <- MVar.newEmptyMVar
              _ <- forkProcess node $ do
                let procSpec = shell "ls FOO"
                    handleExitCode (ExitCode code) =
                      liftIO $ MVar.putMVar resultVar (Just code)
                listenerPid <- Process.getSelfPid
                processPid <-
                  startSystemProcess $ procSpec { exit_code = sendToPid listenerPid }
                Process.receiveWait [ Process.matchIf isExitCode handleExitCode ]
              MVar.takeMVar resultVar >>= assertEqual "should have code 2" (Just 2)


          it "returns exit code 0" $ do
            resultVar <- MVar.newEmptyMVar
            _ <- forkProcess node $ do
              let procSpec = shell "ls LICENSE"
                  handleExitCode (ExitCode code) =
                    liftIO $ MVar.putMVar resultVar code
              listenerPid <- Process.getSelfPid
              processPid <-
                startSystemProcess $ procSpec { exit_code = sendToPid listenerPid }
              Process.receiveWait [ Process.matchIf isExitCode handleExitCode ]
            MVar.takeMVar resultVar >>= assertEqual "should have code 0" 0

          it "returns stdout successfuly" $ do
            resultVar <- MVar.newEmptyMVar
            _ <- forkProcess node $ do
              let procSpec = shell "ls LICENSE"
                  handleStdOut (StdOut text) =
                    liftIO $ MVar.putMVar resultVar text
              listenerPid <- Process.getSelfPid
              processPid <-
                startSystemProcess $ procSpec { std_out = sendToPid listenerPid }
              Process.receiveWait [ Process.matchIf isStdOut handleStdOut ]
            MVar.takeMVar resultVar >>=
                assertEqual "should have correct output" "LICENSE\n"

          it "returns both exit code and stdout" $ do
            stdoutVar <- MVar.newEmptyMVar
            exitCodeVar <- MVar.newEmptyMVar
            _ <- forkProcess node $ do
              let procSpec = shell "ls LICENSE"
                  handleExitCode (ExitCode code) =
                    liftIO $ MVar.putMVar exitCodeVar code
                  handleStdOut (StdOut text) =
                    liftIO $ MVar.putMVar stdoutVar text
              listenerPid <- Process.getSelfPid
              processPid <-
                startSystemProcess $ procSpec { std_out = sendToPid listenerPid
                                              , exit_code = sendToPid listenerPid }

              replicateM_ 2 $
                Process.receiveWait [ Process.matchIf isStdOut handleStdOut
                                    , Process.matchIf isExitCode handleExitCode ]

            MVar.takeMVar stdoutVar >>=
                assertEqual "should have correct output" "LICENSE\n"
            MVar.takeMVar exitCodeVar >>=
                assertEqual "should have correct exit code" 0

        describe "system process that doesn't exist" $
          it "fails misserably with a 127 exit code" $ do
            resultVar <- MVar.newEmptyMVar
            _ <- forkProcess node $ do
              let procSpec = shell "undefined_cmd"
                  handleExitCode (ExitCode code) =
                    liftIO $ MVar.putMVar resultVar (Just code)
              listenerPid <- Process.getSelfPid
              processPid <-
                startSystemProcess $ procSpec { exit_code = sendToPid listenerPid }
              Process.receiveWait [ Process.matchIf isExitCode handleExitCode ]
            MVar.takeMVar resultVar >>= assertEqual "should have code 127" (Just 127)

        describe "using shell pipes" $ do
          it "should not fail with valid commands" $ do
            resultVar <- MVar.newEmptyMVar
            _ <- forkProcess node $ do
              let procSpec = shell "ls | grep LICENSE"
                  handleExitCode (ExitCode code) =
                    liftIO $ MVar.putMVar resultVar (Just code)
              listenerPid <- Process.getSelfPid
              processPid <-
                startSystemProcess $ procSpec { exit_code = sendToPid listenerPid }
              Process.receiveWait [ Process.matchIf isExitCode handleExitCode ]
            MVar.takeMVar resultVar >>= assertEqual "should have code 0" (Just 0)

          it "should fail appropietly with invalid commands" $ do
            resultVar <- MVar.newEmptyMVar
            _ <- forkProcess node $ do
              let procSpec = shell "ls | unknown_command"
                  handleExitCode (ExitCode code) =
                    liftIO $ MVar.putMVar resultVar (Just code)
              listenerPid <- Process.getSelfPid
              processPid <-
                startSystemProcess $ procSpec { exit_code = sendToPid listenerPid }
              Process.receiveWait [ Process.matchIf isExitCode handleExitCode ]
            MVar.takeMVar resultVar >>= assertEqual "should have code 127" (Just 127)


      describe "using proc constructor" $ do
        describe "system process that exists" $ do

          describe "when it fails" $
            it "returns appropiate exit code" $ do
              resultVar <- MVar.newEmptyMVar
              _ <- forkProcess node $ do
                let procSpec = proc "ls" ["FOO"]
                    handleExitCode (ExitCode code) =
                      liftIO $ MVar.putMVar resultVar (Just code)
                listenerPid <- Process.getSelfPid
                processPid <-
                  startSystemProcess $ procSpec { exit_code = sendToPid listenerPid }
                Process.receiveWait [ Process.matchIf isExitCode handleExitCode ]
              MVar.takeMVar resultVar >>= assertEqual "should have code 2" (Just 2)


          it "returns exit code 0" $ do
            resultVar <- MVar.newEmptyMVar
            _ <- forkProcess node $ do
              let procSpec = proc "ls" ["LICENSE"]
                  handleExitCode (ExitCode code) =
                    liftIO $ MVar.putMVar resultVar code
              listenerPid <- Process.getSelfPid
              processPid <-
                startSystemProcess $ procSpec { exit_code = sendToPid listenerPid }
              Process.receiveWait [ Process.matchIf isExitCode handleExitCode ]
            MVar.takeMVar resultVar >>= assertEqual "should have code 0" 0

          it "returns stdout successfuly" $ do
            resultVar <- MVar.newEmptyMVar
            _ <- forkProcess node $ do
              let procSpec = proc "ls" ["LICENSE"]
                  handleStdOut (StdOut text) =
                    liftIO $ MVar.putMVar resultVar text
              listenerPid <- Process.getSelfPid
              processPid <-
                startSystemProcess $ procSpec { std_out = sendToPid listenerPid }
              Process.receiveWait [ Process.matchIf isStdOut handleStdOut ]
            MVar.takeMVar resultVar >>=
                assertEqual "should have correct output" "LICENSE\n"

          it "returns both exit code and stdout" $ do
            stdoutVar <- MVar.newEmptyMVar
            exitCodeVar <- MVar.newEmptyMVar
            _ <- forkProcess node $ do
              let procSpec = proc "ls" ["LICENSE"]
                  handleExitCode (ExitCode code) =
                    liftIO $ MVar.putMVar exitCodeVar code
                  handleStdOut (StdOut text) =
                    liftIO $ MVar.putMVar stdoutVar text
              listenerPid <- Process.getSelfPid
              processPid <-
                startSystemProcess $ procSpec { std_out = sendToPid listenerPid
                                              , exit_code = sendToPid listenerPid }

              replicateM_ 2 $
                Process.receiveWait [ Process.matchIf isStdOut handleStdOut
                                    , Process.matchIf isExitCode handleExitCode ]

            MVar.takeMVar stdoutVar >>=
                assertEqual "should have correct output" "LICENSE\n"
            MVar.takeMVar exitCodeVar >>=
                assertEqual "should have correct exit code" 0

        describe "system process that doesn't exist" $
          it "fails misserably with a 127 exit code" $ do
            resultVar <- MVar.newEmptyMVar
            _ <- forkProcess node $ do
              let procSpec = proc "undefined_cmd" []
                  handleExitCode (ExitCode code) =
                    liftIO $ MVar.putMVar resultVar (Just code)
              listenerPid <- Process.getSelfPid
              processPid <-
                startSystemProcess $ procSpec { exit_code = sendToPid listenerPid }
              Process.receiveWait [ Process.matchIf isExitCode handleExitCode ]
            MVar.takeMVar resultVar >>= assertEqual "should have code 127" (Just 127)
