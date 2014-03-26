{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}
module Main where

import Data.ByteString.Char8 as B8
import Control.Monad (forever, void, replicateM_)
import Control.Monad.Trans (MonadIO(..))
import Control.Concurrent (threadDelay)
import qualified Control.Concurrent.MVar as MVar
import Network.Transport.Chan (createTransport)
import Control.Distributed.Process.Node (forkProcess, newLocalNode, initRemoteTable)
import qualified Control.Distributed.Process as Process

import Test.Hspec
import Test.HUnit (assertEqual)

import System.IO (stdout, hSetBuffering, BufferMode(LineBuffering))

import Control.Distributed.Process.SystemProcess



main :: IO ()
main = do
    hSetBuffering stdout LineBuffering
    transport <- createTransport
    node <- newLocalNode transport initRemoteTable
    let
      assertSysProcess :: ProcessSpec
                       -> (Int, Maybe ByteString, Maybe ByteString)
                       -> (Process.ProcessId -> Process.Process ())
                       -> IO ()
      assertSysProcess procSpec (code, mOut, mErr) callback = do
          stdoutBuffer <- MVar.newMVar []
          stderrBuffer <- MVar.newMVar []
          resultVar <- MVar.newEmptyMVar
          processId <- forkProcess node $ do
            let procSpec = proc "cat" []
                handleEvent (StdOut bs) = liftIO $
                  MVar.modifyMVar_ stdoutBuffer (return . (bs:))
                handleEvent (StdErr bs) = liftIO $
                  MVar.modifyMVar_ stderrBuffer (return . (bs:))
                handleEvent (ExitCode code) = liftIO $ MVar.putMVar resultVar code

            listenerPid <- spawnLocalRevLink "listener"
                             $ forever
                             $ Process.receiveWait [ Process.match handleEvent ]

            processPid <- spawnLocalRevLink "system-proc" $ do
              runSystemProcess $ procSpec { std_err = sendToPid listenerPid
                                          , std_out = sendToPid listenerPid
                                          , exit_code = sendToPid listenerPid }

            Process.link processPid
            callback processPid

            forever $ liftIO $ threadDelay 1000999

          MVar.takeMVar resultVar >>= assertEqual ("should have code " ++ show code) code
          checkOutput "stdout" stdoutBuffer mOut
          checkOutput "stderr" stderrBuffer mErr
        where
          checkOutput _ _ Nothing = return ()
          checkOutput name buffer (Just expected) = do
            got <- B8.concat `fmap` MVar.takeMVar buffer
            assertEqual (name ++ " should equal") expected got

    hspec $ do
      -- WIP
      -- describe "terminateProcess" $ do
      --   it "terminates running process" $ do


      describe "sending input to process" $ do
        it "and reading output work correctly" $ do
          stdoutBuffer <- MVar.newMVar []
          stderrBuffer <- MVar.newMVar []
          resultVar <- MVar.newEmptyMVar
          _ <- forkProcess node $ do
            let procSpec = proc "cat" []
                handleEvent (StdOut bs) = liftIO $
                  MVar.modifyMVar_ stdoutBuffer (return . (bs:))
                handleEvent (StdErr bs) = liftIO $
                  MVar.modifyMVar_ stderrBuffer (return . (bs:))
                handleEvent (ExitCode code) = liftIO $ MVar.putMVar resultVar code

            currentPid <- Process.getSelfPid
            listenerPid <- Process.spawnLocal $ do
                replicateM_ 2 $
                  Process.receiveWait [ Process.match handleEvent ]
            processPid <-
              startSystemProcess $ procSpec { std_err = sendToPid listenerPid
                                            , std_out = sendToPid listenerPid
                                            , exit_code = sendToPid listenerPid }

            writeStdin processPid "hello"
            liftIO $ threadDelay 1000
            closeStdin processPid

          MVar.takeMVar resultVar >>= assertEqual "should have code 0" 0
          MVar.takeMVar stdoutBuffer >>= assertEqual "should echo input" ["hello"]
          MVar.takeMVar stderrBuffer >>= assertEqual "should have no stderr" []

      describe "using shell constructor" $ do
        describe "system process that exists" $ do

          describe "when it fails" $
            it "returns appropiate exit code (no sigpipe errors)" $ do
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
              void $ startSystemProcess $ procSpec { exit_code = sendToPid listenerPid }
              Process.receiveWait [ Process.matchIf isExitCode handleExitCode ]
            MVar.takeMVar resultVar >>= assertEqual "should have code 0" 0

          it "returns stdout successfuly" $ do
            resultVar <- MVar.newEmptyMVar
            _ <- forkProcess node $ do
              let procSpec = shell "ls LICENSE"
                  handleOutput (StdOut text) =
                    liftIO $ MVar.putMVar resultVar text
              listenerPid <- Process.getSelfPid
              processPid <-
                startSystemProcess $ procSpec { std_out = sendToPid listenerPid }
              Process.receiveWait [ Process.matchIf isStdOut handleOutput ]
            MVar.takeMVar resultVar >>=
                assertEqual "should have correct output" "LICENSE\n"

          it "returns both exit code and stdout" $ do
            stdoutVar <- MVar.newEmptyMVar
            exitCodeVar <- MVar.newEmptyMVar
            _ <- forkProcess node $ do
              let procSpec = shell "ls LICENSE"
                  handleExitCode (ExitCode code) =
                    liftIO $ MVar.putMVar exitCodeVar code
                  handleOutput (StdOut text) =
                    liftIO $ MVar.putMVar stdoutVar text
              listenerPid <- Process.getSelfPid
              processPid <-
                startSystemProcess $ procSpec { std_out = sendToPid listenerPid
                                              , exit_code = sendToPid listenerPid }

              replicateM_ 2 $
                Process.receiveWait [ Process.matchIf isStdOut handleOutput
                                    , Process.matchIf isExitCode handleExitCode ]

            MVar.takeMVar stdoutVar >>=
                assertEqual "should have correct output" "LICENSE\n"
            MVar.takeMVar exitCodeVar >>=
                assertEqual "should have correct exit code" 0

        describe "system process that doesn't exist" $
          it "fails with a 127 exit code" $ do
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
                  handleOutput (StdOut text) =
                    liftIO $ MVar.putMVar resultVar text
              listenerPid <- Process.getSelfPid
              processPid <-
                startSystemProcess $ procSpec { std_out = sendToPid listenerPid }
              Process.receiveWait [ Process.matchIf isStdOut handleOutput ]
            MVar.takeMVar resultVar >>=
                assertEqual "should have correct output" "LICENSE\n"

          it "returns both exit code and stdout" $ do
            stdoutVar <- MVar.newEmptyMVar
            exitCodeVar <- MVar.newEmptyMVar
            _ <- forkProcess node $ do
              let procSpec = proc "ls" ["LICENSE"]
                  handleExitCode (ExitCode code) =
                    liftIO $ MVar.putMVar exitCodeVar code
                  handleOutput (StdOut text) =
                    liftIO $ MVar.putMVar stdoutVar text
              listenerPid <- Process.getSelfPid
              processPid <-
                startSystemProcess $ procSpec { std_out = sendToPid listenerPid
                                              , exit_code = sendToPid listenerPid }

              replicateM_ 2 $
                Process.receiveWait [ Process.matchIf isStdOut handleOutput
                                    , Process.matchIf isExitCode handleExitCode ]

            MVar.takeMVar stdoutVar >>=
                assertEqual "should have correct output" "LICENSE\n"
            MVar.takeMVar exitCodeVar >>=
                assertEqual "should have correct exit code" 0

        describe "system process that doesn't exist" $
          it "fails with a 127 exit code" $ do
            resultVar <- MVar.newEmptyMVar
            _ <- forkProcess node $ do
              let procSpec = proc "undefined_cmd" []
                  handleExitCode _ = return ()
                  handleExitCode (ExitCode code) =
                    liftIO $ MVar.putMVar resultVar (Just code)
              listenerPid <- Process.getSelfPid
              processPid <-
                startSystemProcess $ procSpec { exit_code = sendToPid listenerPid }
              Process.receiveWait [ Process.matchIf isExitCode handleExitCode ]
            MVar.takeMVar resultVar >>= assertEqual "should have code 127" (Just 127)
