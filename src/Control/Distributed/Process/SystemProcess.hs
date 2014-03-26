{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE DeriveDataTypeable #-}
{-# LANGUAGE DeriveGeneric      #-}
module Control.Distributed.Process.SystemProcess
       (
       -- * Actor API
         runSystemProcess
       , startSystemProcess
       , writeStdin
       , closeStdin
       , terminateProcess

       -- * ProcessSpec constructors
       , shell
       , proc

       -- * ProcessSpec configuration functions
       , castToPid
       , sendToPid
       , sendToChan
       , ignore

       -- * Stream query functions
       , isExitCode
       , isStdOut
       , isStdErr

       , CmdSpec(..)
       , ProcessSpec(..)
       , ProcessStream(..)
       , Transport


       , logMsg
       , spawnLocalRevLink
       ) where

import Control.Monad (void)
import Control.Monad.Trans (lift, liftIO)

import Data.Binary   (Binary)
import Data.Typeable (Typeable)
import GHC.Generics  (Generic)

import Data.Conduit (awaitForever, ($$))
import Data.Conduit.Binary (sourceHandle)

import Control.Concurrent (threadDelay)
import Control.Concurrent.Async (async, waitCatch)

import Data.ByteString (hPutStr, ByteString)

import qualified Control.Distributed.Process                         as Process
import qualified Control.Distributed.Process.Platform                as PP
import qualified Control.Distributed.Process.Platform.ManagedProcess as MP
import           Control.Distributed.Process.Platform.Time           (Delay(Infinity))
import           Control.Distributed.Process.Management       (mxNotify, MxEvent(MxLog))

import           System.Exit (ExitCode(..))
import           System.IO (Handle, hClose)
import qualified System.Process as SProcess

--------------------

import qualified Control.Exception as C
import GHC.IO.Exception (IOErrorType(..), IOException(..))
import Foreign.C.Error (Errno(..), ePIPE)


--------------------------------------------------------------------------------
-- Types

data CmdSpec
  = ShellCommand !String
  | RawCommand !FilePath ![String]
  deriving (Show, Generic, Typeable)

instance Binary CmdSpec

--------------------

data ProcessStream
  = StdOut !ByteString
  | StdErr !ByteString
  | ExitCode !Int
  deriving (Show, Generic, Typeable)

instance Binary ProcessStream

isStdErr :: ProcessStream -> Bool
isStdErr (StdErr _) = True
isStdErr _ = False

isStdOut :: ProcessStream -> Bool
isStdOut (StdOut _) = True
isStdOut _ = False

isExitCode :: ProcessStream -> Bool
isExitCode (ExitCode {}) = True
isExitCode _ = False

--------------------

data Transport
  = CastMessage !Process.ProcessId
  | SendMessage !Process.ProcessId
  | SendChan !(Process.SendPort ProcessStream)
  | Ignore
  deriving (Show, Generic, Typeable)

instance Binary Transport

castToPid :: Process.ProcessId -> Transport
castToPid = CastMessage

sendToPid :: Process.ProcessId -> Transport
sendToPid = SendMessage

sendToChan :: Process.SendPort ProcessStream -> Transport
sendToChan = SendChan

ignore :: Transport
ignore = Ignore

--------------------

data ProcessSpec
  = ProcessSpec {
    cmdspec       :: CmdSpec
  , cwd           :: Maybe FilePath
  , env           :: Maybe [(String, String)]
  , std_out       :: Transport
  , std_err       :: Transport
  , exit_code     :: Transport
  , close_fds     :: Bool
  , create_group  :: Bool
  , delegate_ctlc :: Bool
  }
  deriving (Show, Generic, Typeable)

instance Binary ProcessSpec

newtype StdinMessage
  = StdinMessage ByteString
  deriving (Show, Typeable, Binary)

newtype StdinEOF
  = StdinEOF ()
  deriving (Show, Typeable, Binary)

newtype TerminateMessage
  = TerminateMessage ()
  deriving (Show, Typeable, Binary)

data State
  = State {
    _stateStdin       :: Handle
  , _stateProcHandle  :: SProcess.ProcessHandle
  , _stateProcessSpec :: ProcessSpec
  }


--------------------------------------------------------------------------------
-- [Private] Copied from System.Process

ignoreSigPipe :: IO () -> IO ()
ignoreSigPipe =
  C.handle $
    \e -> case e of
      IOError { ioe_type = ResourceVanished
              , ioe_errno = Just ioe }
        | Errno ioe == ePIPE -> return ()
      _ -> C.throwIO e



--------------------------------------------------------------------------------
-- [Private] System Process functions

logMsg :: String -> Process.Process ()
logMsg msg = do
  self <- Process.getSelfPid
  mxNotify . MxLog $ show self ++ ": " ++ msg

cleanupProcess :: State -> Process.Process ()
cleanupProcess (State _ procHandle procSpec) = do
    liftIO (SProcess.getProcessExitCode procHandle) >>= cleanupProcess' retryCount
  where
    transport = exit_code procSpec
    retryCount :: Int
    retryCount = 15
    delayTimeout :: Int
    delayTimeout = 500111
    gaveUpExitCode = (-99)

    cleanupProcess' _ (Just exitCode) =
      case exitCode of
        ExitSuccess -> sendProcessStream transport $ ExitCode 0
        ExitFailure n -> sendProcessStream transport $ ExitCode n
    cleanupProcess' 0 _ = do
      sendProcessStream transport $ ExitCode gaveUpExitCode
    cleanupProcess' n Nothing = do
      liftIO $ SProcess.terminateProcess procHandle
      liftIO $ threadDelay delayTimeout
      liftIO (SProcess.getProcessExitCode procHandle) >>=
        cleanupProcess' (pred n)

shouldSendStream :: Transport -> Bool
shouldSendStream Ignore = False
shouldSendStream _ = True

sendProcessStream :: Transport -> ProcessStream -> Process.Process ()
sendProcessStream (CastMessage pid) = MP.cast pid
sendProcessStream (SendMessage pid) = Process.send pid
sendProcessStream (SendChan chan)   = Process.sendChan chan
sendProcessStream _ = const $ return ()

spawnLocalRevLink :: String
                      -> Process.Process ()
                      -> Process.Process Process.ProcessId
spawnLocalRevLink debugName action = do
  selfPid <- Process.getSelfPid
  Process.spawnLocal $ do
    logMsg $ "Spawned " ++ debugName
    Process.link selfPid
    action

createHandlerStreamer
  :: Transport
  -> (ByteString -> ProcessStream)
  -> Handle
  -> Process.Process ()
createHandlerStreamer transport streamCtor handle = do
    logMsg $ "create transport for handle "
         ++ show handle ++ " with transport " ++ show transport
    if shouldSendStream transport
      then void $
             spawnLocalRevLink ("handleStreamer " ++ show handle) handleStreamer
      else do
        logMsg "not using handler, ignoring it."
        sourceHandle handle $$ awaitForever (const $ return ())
  where
    handleStreamer =
      sourceHandle handle $$
        awaitForever (lift . sendProcessStream transport . streamCtor)

createExitCodeWatcher
  :: SProcess.ProcessHandle
  -> Process.Process Process.ProcessId
createExitCodeWatcher processHandle = do
  managerPid <- Process.getSelfPid
  spawnLocalRevLink "exitCodeWatcher" $ do

    -- NOTE: The usage of async is necessary here, for some
    -- reason distributed-process crashes if there is a failure
    exitCode <- liftIO
                  $ async (SProcess.waitForProcess processHandle) >>= waitCatch
    logMsg $ "child process has exited with exitCode: " ++ show exitCode
    logMsg "calling shutdown on managerPid"
    MP.shutdown managerPid


--------------------------------------------------------------------------------
-- [Private] Managed Process handlers

handleStdIn :: State
            -> StdinMessage
            -> Process.Process (MP.ProcessAction State)
handleStdIn st@(State stdin _ _) (StdinMessage bytes) = do
  liftIO $ ignoreSigPipe $ hPutStr stdin bytes
  MP.continue st

handleStdInEOF :: State
               -> StdinEOF
               -> Process.Process (MP.ProcessAction State)
handleStdInEOF st@(State stdin _ _) _ = do
  liftIO $ ignoreSigPipe $ hClose stdin
  MP.continue st

handleTermination :: State
                  -> TerminateMessage
                  -> Process.Process (MP.ProcessReply () State)
handleTermination st _ = do
  _ <- MP.stopWith st PP.ExitNormal
  MP.reply () st

handleShutdown :: State -> PP.ExitReason -> Process.Process ()
handleShutdown st _ = do
  cleanupProcess st

processDefinition :: MP.ProcessDefinition State
processDefinition =
  MP.defaultProcess  {
    MP.apiHandlers = [
      MP.handleCast handleStdIn
    , MP.handleCast handleStdInEOF
    , MP.handleCall handleTermination
    ]
    , MP.shutdownHandler = handleShutdown
  }

--------------------------------------------------------------------------------
-- Public

shell :: String -> ProcessSpec
shell cmd =
  ProcessSpec { cmdspec = ShellCommand cmd
              , cwd = Nothing
              , env = Nothing
              , std_out = ignore
              , std_err = ignore
              , exit_code = ignore
              , close_fds = False
              , create_group = False
              , delegate_ctlc = False }

proc :: FilePath -> [String] -> ProcessSpec
proc path args =
  ProcessSpec { cmdspec = RawCommand path args
              , cwd = Nothing
              , env = Nothing
              , std_out = ignore
              , std_err = ignore
              , exit_code = ignore
              , close_fds = False
              , create_group = False
              , delegate_ctlc = False }

runSystemProcess :: ProcessSpec -> Process.Process ()
runSystemProcess procSpec = do
    -- NOTE: The usage of async is necessary here, for some
    -- reason distributed-process crashes if the exec name is invalid
    procAsync <- liftIO . async $ SProcess.createProcess sysProcessSpec
    result <- liftIO $ waitCatch procAsync
    case result of
      Right (Just stdin, Just stdout, Just stderr, procHandle) -> do
        logMsg "systemProcess manager starting"
        let st = State stdin procHandle procSpec
        Process.finally
          (do void $ createExitCodeWatcher procHandle
              createHandlerStreamer (std_out procSpec) StdOut stdout
              createHandlerStreamer (std_err procSpec) StdErr stderr
              MP.serve st start processDefinition)
          (cleanupProcess st)
      _ -> do
        logMsg "systemProcess failed to start"
        sendProcessStream (exit_code procSpec) (ExitCode 127)
  where
    start st = do
      logMsg "systemProcess manager running managed process"
      return $ MP.InitOk st Infinity
    sysCmdspec = case cmdspec procSpec of
      RawCommand path args -> SProcess.RawCommand path args
      ShellCommand str -> SProcess.ShellCommand str
    sysProcessSpec = SProcess.CreateProcess {
        SProcess.cmdspec = sysCmdspec
      , SProcess.cwd = cwd procSpec
      , SProcess.env = Nothing
      , SProcess.std_in  = SProcess.CreatePipe
      , SProcess.std_out = SProcess.CreatePipe
      , SProcess.std_err = SProcess.CreatePipe
      , SProcess.close_fds = close_fds procSpec
      , SProcess.create_group = create_group procSpec
      -- , SProcess.delegate_ctlc = delegate_ctlc procSpec
      }

startSystemProcess :: ProcessSpec -> Process.Process Process.ProcessId
startSystemProcess = Process.spawnLocal . runSystemProcess

writeStdin :: Process.ProcessId -> ByteString -> Process.Process ()
writeStdin pid = MP.cast pid . StdinMessage

closeStdin :: Process.ProcessId -> Process.Process ()
closeStdin pid = MP.cast pid $ StdinEOF ()

terminateProcess :: Process.ProcessId -> Process.Process ()
terminateProcess pid = MP.call pid $ TerminateMessage ()
