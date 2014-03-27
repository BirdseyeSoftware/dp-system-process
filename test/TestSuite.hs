{-# LANGUAGE OverloadedStrings   #-}
{-# LANGUAGE ScopedTypeVariables #-}
module Main where

import           Control.Concurrent               (threadDelay)
import qualified Control.Concurrent.MVar          as MVar
import qualified Control.Distributed.Process      as Process
import           Control.Distributed.Process.Node (LocalNode, forkProcess,
                                                   initRemoteTable,
                                                   newLocalNode)
import           Control.Monad                    (forever, replicateM_, void)
import           Control.Monad.Trans              (MonadIO (..))
import           Data.ByteString.Char8            as B8
import           Network.Transport.Chan           (createTransport)

import Test.Hspec
import Test.HUnit (assertEqual)

import System.IO (BufferMode (LineBuffering), hSetBuffering, stdout)

import Control.Distributed.Process.SystemProcess

--------------------------------------------------------------------------------

data TransportType
  = Cast
  | Send
  | Channel
  deriving (Show, Eq)

assertSysProcess :: TransportType
                 -> LocalNode
                 -> ProcessSpec
                 -> (Int, Maybe ByteString, Maybe ByteString)
                 -> (Process.ProcessId -> Process.Process ())
                 -> IO ()
assertSysProcess Send = assertSysProcessSend

assertSysProcessSend :: LocalNode
                     -> ProcessSpec
                     -> (Int, Maybe ByteString, Maybe ByteString)
                     -> (Process.ProcessId -> Process.Process ())
                     -> IO ()
assertSysProcessSend node procSpec (code, mOut, mErr) callback = do
    stdoutBuffer <- MVar.newMVar []
    stderrBuffer <- MVar.newMVar []
    resultVar <- MVar.newEmptyMVar
    processId <- forkProcess node $ do
      let handleEvent (StdOut bs) = liftIO $
            MVar.modifyMVar_ stdoutBuffer (return . (bs:))
          handleEvent (StdErr bs) = liftIO $
            MVar.modifyMVar_ stderrBuffer (return . (bs:))
          handleEvent (ExitCode code) = liftIO $ MVar.putMVar resultVar code

      listenerPid <- spawnLocalRevLink "listener"
                       $ forever
                       $ Process.receiveWait [ Process.match handleEvent ]

      processPid <- spawnLocalRevLink "system-proc" $ do
        runSystemProcess $ procSpec { std_err = getTransport listenerPid mErr
                                    , std_out = getTransport listenerPid mOut
                                    , exit_code = sendToPid listenerPid }

      Process.link processPid
      callback processPid

      forever $ liftIO $ threadDelay 1000999

    MVar.takeMVar resultVar >>=
      assertEqual ("should have exit code " ++ show code) code
    checkOutput "stdout" stdoutBuffer mOut
    checkOutput "stderr" stderrBuffer mErr
  where
    getTransport listenerPid (Just _) = sendToPid listenerPid
    getTransport _ Nothing = ignore

    checkOutput _ _ Nothing = return ()
    checkOutput name buffer (Just expected) = do
      got <- B8.concat `fmap` MVar.takeMVar buffer
      assertEqual (name ++ " should equal") expected got

--------------------------------------------------------------------------------

--
-- using shell constructor / using proc constructor
--
specs :: LocalNode -> TransportType -> Spec
specs node transportType = do

  describe "short-lived process" $ do
    describe "when command is valid with invalid args" $
      it "returns error exit code" $
        assertSysProcess transportType
                         node
                         (shell "ls FOO")
                         (2, Nothing, Nothing)
                         (const $ return ())

    describe "when command is valid" $ do
      it "prints correctly on stdout" $
        assertSysProcess transportType
                         node
                         (shell "echo -n hello")
                         (0, Just "hello", Just "")
                         (const $ return ())

      it "prints correctly on stderr" $
        assertSysProcess transportType
                         node
                         (shell "echo -n hello >&2")
                         (0, Just "", Just "hello")
                         (const $ return ())

      it "prints correctly on stdout and stderr" $
        assertSysProcess transportType
                         node
                         (shell "{ echo hello >&2; echo hola; }")
                         (0, Just "hola\n", Just "hello\n")
                         (const $ return ())

  describe "long-lived process" $ do
    describe "when commad is valid and alive" $ do

      describe "and stdin is open" $
        it "process receives stdin correctly" $ do
          assertSysProcess transportType
                           node
                           (shell "test/test_command.sh")
                           (0, Just "out\nout\n", Just "err\nerr\n")
                           (\pid -> do
                               writeStdin pid "continue\n"
                               writeStdin pid "stop\n")


      describe "and stdin is closed" $
        it "process dies with an exit code 15" $
          assertSysProcess transportType
                           node
                           (shell "test/test_command.sh")
                           (15, Just "", Just "")
                           (\pid -> do
                               writeStdinAsync pid "continue\n"
                               closeStdin pid
                               writeStdinAsync pid "stop\n")

    describe "when command is valid and process is gone" $
      it "ignores any stdin sent to it" $
        assertSysProcess transportType
                         node
                         (shell "test/test_command.sh")
                         -- NOTE: if Nothing is used the
                         -- process hangs
                         (15, Just "", Just "")
                         (\pid -> do
                             writeStdin pid "continue\n"
                             liftIO $ threadDelay 1000
                             terminateProcess pid
                             writeStdin pid "stop\n")


  describe "when command doesn't exist" $
    it "returns exit code 127" $
      assertSysProcess transportType
                       node
                       (shell "non_existing")
                       -- NOTE: if Nothing is used the
                       -- process hangs
                       (127, Nothing, Nothing)
                       (const $ return ())

  describe "when terminateProcess is called" $ do
    it "returns exit code SIGTERM" $
      assertSysProcess transportType
                       node
                       (shell "cat")
                       -- NOTE: if Nothing is used the
                       -- process hangs
                       (15, Just "", Just "")
                       (terminateProcess)



main :: IO ()
main = do
    hSetBuffering stdout LineBuffering
    transport <- createTransport
    node <- newLocalNode transport initRemoteTable
    hspec $ do
      specs node Send
