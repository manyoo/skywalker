{-# LANGUAGE CPP, GeneralizedNewtypeDeriving, ScopedTypeVariables, OverloadedStrings, JavaScriptFFI, GADTs, FlexibleInstances #-}
module Skywalker.App where

import Control.Monad
import Control.Monad.State
import Control.Monad.Reader
import Control.Monad.IO.Class
import Control.Concurrent
import Control.Concurrent.MVar
import Control.Concurrent.Chan
import Control.Concurrent.STM
import Data.Maybe (isJust, fromJust)
import Data.Default

import qualified Data.ByteString as BS
import qualified Data.ByteString.Char8 as Char8
import qualified Data.ByteString.Lazy as LBS
import Data.Map (Map)
import qualified Data.Map as M

import Skywalker.UUID (UUID)
import qualified Skywalker.UUID as UUID

-- import the different library for JSON
#if defined(ghcjs_HOST_OS)
import JavaScript.JSON.Types
import JavaScript.JSON.Types.Class
import JavaScript.JSON.Types.Internal
import JavaScript.JSON.Types.Instances
import JavaScript.Web.XMLHttpRequest
import qualified JavaScript.Web.MessageEvent as ME

import Data.IORef
import Data.JSString hiding (reverse)

import Skywalker.EventSource
#elif defined(client)

import Data.IORef
import Data.Aeson
import Data.Text hiding (reverse, concat)

import Network.HTTP.Simple (parseRequest, setRequestBodyJSON, httpJSON, getResponseBody)

#else
import Control.Exception (SomeException, handle)

import Data.Aeson
import Data.Text
import qualified Data.UUID as UUID
import Skywalker.RestServer

import Network.Wai
import Network.Wai.EventSource
#endif

import Skywalker.StaticApp

newtype URL = URL {
#if defined(ghcjs_HOST_OS)
    urlString :: JSString
#else
    urlString :: String
#endif
}

-- easier to read alias for JSON value
type JSON = Value

fromResult :: Result a -> a
fromResult (Success a) = a
fromResult (Error e) = error e

-- a special data type for forcing the use of runClient as the last
-- operation in App monad
data AppDone = AppDone

-- a UUID to represent a client app
type ClientID = UUID

-- MethodName is the name of a remote server function available to the client side.
type MethodName = String

-- a remote method is an IO action that accepts a list of JSON and return a JSON result
type RemoteMethod = [JSON] -> Server JSON

-- specify whether the remote method is execuated in a sync, async or subscription based way
data MethodMode = MethodAsync
                | MethodSubscribe
                deriving Eq

-- the state stored in the App monad, it is a map of all the defined remote functions
#if defined(ghcjs_HOST_OS)
-- client side app state will include the mapping of subscription channels
type AppState = M.Map MethodName (Chan JSON)
#else
type AppState = M.Map MethodName (MethodMode, RemoteMethod)
#endif

data AppMode = AppClassic  -- classic CS architecture. clients call server APIs
             | AppPubSub   -- PubSub mode that servers can send SSE to clients
             deriving Eq

-- the top-level App monad for the whole app
newtype App a = App { unApp :: ReaderT AppMode (StateT AppState IO) a }
              deriving (Functor, Applicative, Monad, MonadIO, MonadState AppState, MonadReader AppMode)

-- run the top-level App monad and return an IO action. This should be used at the begining
-- of the whole application
runApp :: AppMode -> App AppDone -> IO ()
runApp m app = void $ flip runStateT M.empty $ flip runReaderT m $ unApp app

-- define a value that be used in remote functions
class Remotable a where
    mkRemote :: a -> RemoteMethod

instance (ToJSON a) => Remotable (Server a) where
    mkRemote m _ = fmap toJSON m

instance (FromJSON a, Remotable b) => Remotable (a -> b) where
    mkRemote f (x:xs) = mkRemote (f jx) xs
        where Success jx = fromJSON x

#if defined(ghcjs_HOST_OS) || defined(client)
-- on the client side, we don't care about Server values, so it's just a dummy value
data Server a = ServerDummy

instance Functor Server where
    fmap _ _ = ServerDummy

instance Applicative Server where
    pure _ = ServerDummy
    _ <*> _ = ServerDummy

instance Monad Server where
    return _ = ServerDummy
    _ >>= _ = ServerDummy

instance MonadIO Server where
    liftIO _ = ServerDummy

-- for a remote value, we just need to remember the MethodName and arguments for it
data Remote a = Remote MethodName MethodMode [JSON]
#else

type SSEChannelMap = Map ClientID (Chan ServerEvent)

data ServerEnv = ServerEnv {
    seClientId       :: Maybe ClientID,
    seSSEChanMapTVar :: Maybe (TVar SSEChannelMap)
    }

instance Default ServerEnv where
    def = ServerEnv Nothing Nothing

type Server a = ReaderT ServerEnv IO a

runServerM e = flip runReaderT e

-- remote values are not interested on the server side either
data Remote a = RemoteDummy

#endif

(<.>) :: ToJSON a => Remote (a -> b) -> a -> Remote b
#if defined(ghcjs_HOST_OS) || defined(client)
(Remote name mode args) <.> arg = Remote name mode (toJSON arg : args)
#else
_ <.> _ = RemoteDummy
#endif

-- convert a Remotable value to a Remote
remote :: Remotable a => MethodName -> a -> App (Remote a)
remote = remoteWithMode MethodAsync

remoteChannel :: Remotable a => MethodName -> a -> App (Remote a)
remoteChannel = remoteWithMode MethodSubscribe

remoteWithMode :: Remotable a => MethodMode -> MethodName -> a -> App (Remote a)
#if defined(ghcjs_HOST_OS) || defined(client)
-- client side, just remember the name in the Remote value
remoteWithMode m n _ = do
    when (m == MethodSubscribe) $ do
        methodMap <- get
        chan <- liftIO newChan
        put $ M.insert n chan methodMap
    return (Remote n m [])
#else
-- server side, convert the argument value into a Remote and store it in the AppState
remoteWithMode m n f = do
    remotes <- get
    when (M.member n remotes) (error $ "Remote method '" ++ show n ++ "' already defined.")
    put $ M.insert n (m, mkRemote f) remotes
    return RemoteDummy
#endif

-- lift a server side action into the App monad, only takes effect server side
liftServerIO :: IO a -> App (Server a)
#if defined(ghcjs_HOST_OS) || defined(client)
liftServerIO _ = return ServerDummy
#else
liftServerIO m = return <$> liftIO m
#endif

-- Client side definition
#if defined(ghcjs_HOST_OS) || defined(client)
-- define a client environment type with a websocket as well as a variable type
data ClientEnv a = ClientEnv {
    ceUrl      :: URL,
    ceClientId :: ClientID,
    ceSubscriptionMapping :: Map MethodName (Chan JSON),
    ceCustom   :: a
    }
-- a (Client m e a) monad value means a monad with (ClientEnv e) environment,
-- ClientState state, a monad m inside and return value a
type Client e m = ReaderT (ClientEnv e) m
#else
data Client e m a where
    ClientDummy :: Monad m => Client e m a

instance Monad m => Functor (Client e m) where
    fmap _ _ = ClientDummy

instance Monad m => Applicative (Client e m) where
    pure _ = ClientDummy
    _ <*> _ = ClientDummy

instance Monad m => Monad (Client e m) where
    return _ = ClientDummy
    _ >>= _ = ClientDummy

instance Monad m => MonadIO (Client e m) where
    liftIO _ = ClientDummy
#endif

-- get the custom environment data inside Client monad
getClientEnv :: Monad m => Client e m e
#if defined(ghcjs_HOST_OS) || defined(client)
getClientEnv = ceCustom <$> ask
#else
getClientEnv = undefined
#endif

class (Monad c, MonadIO c) => IsClient c where
    onServer :: (FromJSON a, ToJSON a) => Remote (Server a) -> c a
    subscribeOnServer :: (FromJSON a, ToJSON a) => Remote (Server a) -> (a -> IO ()) -> c ()

instance (Monad m, MonadIO m) => IsClient (Client e m) where
    onServer = onServerF
    subscribeOnServer = subscribeOnServerF

onServerF :: (FromJSON a, ToJSON a, Monad m, MonadIO m) => Remote (Server a) -> Client e m a
#if defined(ghcjs_HOST_OS) || defined(client)
onServerF (Remote identifier mode args) = do
    url <- ceUrl <$> ask
    cid <- ceClientId <$> ask

    json <- liftIO $ xhrJSON url identifier cid args

    let Success (result :: JSON) = fromJSON json
    return (fromResult $ fromJSON result)

-- data type and functions to break the onServer into two parts so that
-- users can has lower level control on API requests
data APIParam = APIParam {
    apiURL        :: URL,
    apiIdentifier :: MethodName,
    apiClientId   :: ClientID,
    apiArguments  :: [JSON]
    }

mkAPIParam :: Remote (Server a) -> ClientID -> URL -> APIParam
mkAPIParam (Remote identifier mode args) cid url = APIParam url identifier cid args

processAPIParam :: APIParam -> IO JSON
processAPIParam (APIParam url identifier cid args) = do
    json <- xhrJSON url identifier cid args

    let Success (n :: Int, result :: JSON) = fromJSON json
    return result

xhrJSON :: URL -> MethodName -> ClientID -> [JSON] -> IO JSON
#if defined(ghcjs_HOST_OS)
xhrJSON url identifier cid args = do
    let dat = encode $ toJSON (identifier, cid, reverse args)
        
        req = Request { reqMethod          = POST,
                        reqURI             = "/swapi/swremote",
                        reqLogin           = Nothing,
                        reqHeaders         = [],
                        reqWithCredentials = False,
                        reqData            = StringData dat
                      }
    -- send the actual request and wait for the result
    jsonResp <- fmap parseJSONString <$> xhr req
    let (Just json) = contents jsonResp
    return json
#elif defined(client)
xhrJSON url identifier cid args = do
    req' <- parseRequest $ concat ["POST ", urlString url, "/swapi/swremote"]
    let req = setRequestBodyJSON (identifier, cid, reverse args) req'
    jsonResp <- httpJSON req
    return $ getResponseBody jsonResp
#endif

#else
onServerF _ = ClientDummy
#endif

subscribeOnServerF :: (FromJSON a, ToJSON a, Monad m, MonadIO m) => Remote (Server a) -> (a -> IO ()) -> Client e m ()
#if defined (ghcjs_HOST_OS) || defined(client)
subscribeOnServerF (Remote identifier mode args) cb = do
    url <- ceUrl <$> ask
    cid <- ceClientId <$> ask
    mapping <- ceSubscriptionMapping <$> ask
    let c = mapping M.! identifier

    -- send the actual request and wait for the result
    liftIO $ xhrJSON url identifier cid args

    liftIO $ void $ forkIO $ forever $ do
        res <- (fromResult . fromJSON) <$> readChan c
        cb res
#else
subscribeOnServerF _ _ = ClientDummy
#endif

runClient :: URL -> e -> Client e IO a -> App AppDone
#if defined(ghcjs_HOST_OS) || defined(client)
runClient url env c = do
    cid <- liftIO UUID.generateUUID
    subscribeMapping <- get
    mode <- ask
#if defined(ghcjs_HOST_OS)
    when (mode == AppPubSub) $ liftIO $ do
        es <- mkEventSource $ pack $ "/swsse?clientId=" ++ show cid
        onMessage (onServerMessage subscribeMapping) es
#endif

    liftIO $ runReaderT c (ClientEnv url cid subscribeMapping env)

    return AppDone

#if defined(ghcjs_HOST_OS)
onServerMessage mapping e = do
    let ME.StringData msg = ME.getData e
        res = fromJSON $ parseJSONString msg
    case res of
        Success (identifier :: String, result :: JSON) -> when (M.member identifier mapping) $ writeChan (mapping M.! identifier) result
        Error e -> print e

-- import the javascript JSON.parse function to transform a js string to a JSON Value type
foreign import javascript unsafe "JSON['parse']($1)" parseJSONString :: JSString -> JSON
#endif

#else
runClient _ _ _ = return AppDone
#endif

onEvent :: M.Map MethodName (MethodMode, RemoteMethod) -> JSON -> Server LBS.ByteString
#if defined(ghcjs_HOST_OS) || defined(client)
onEvent _ _ = ServerDummy
#else
-- server side dispatcher of client function calls
onEvent mapping incoming = do
    let Success (identifier :: MethodName, cid :: UUID, args :: [JSON]) = fromJSON incoming
    e <- ask
    let Just (m, f) = M.lookup identifier mapping
        processEvt = f args >>= (return . encode)
        processSub = void $ f args
        newEnv = e { seClientId = Just cid }
    case m of
        MethodAsync -> liftIO $ runServerM newEnv processEvt
        MethodSubscribe -> liftIO $ runServerM newEnv processSub >> return (encode ([] :: [Int]))
#endif

#if defined(ghcjs_HOST_OS) || defined(client)
skywalkerServer :: Int -> a -> App ()
skywalkerServer _ _ = return ()
#else
skywalkerServer :: Int -> Application -> App ()
skywalkerServer port backupApp = do
    remoteMapping <- get
    mode <- ask
    app <- if mode == AppClassic
           then return $ restOr "swapi" (buildRest [("swremote", swRestApp remoteMapping Nothing)]) backupApp
           else do
               sseChannelMapTVar <- liftIO buildSSEChannelMapTVar
               return $ restOr "swapi" (buildRest [("swremote", swRestApp remoteMapping (Just sseChannelMapTVar))]) $ sseApp "swsse" sseChannelMapTVar backupApp
    liftIO $ run port app
    return ()

swRestApp remoteMapping sseChannelMapTVar req = do
    msg <- lazyRequestBody req
    let Just (m :: JSON) = decode msg
    runServerM (def {seSSEChanMapTVar = sseChannelMapTVar }) $ onEvent remoteMapping m

buildSSEChannelMapTVar :: IO (TVar SSEChannelMap)
buildSSEChannelMapTVar = newTVarIO M.empty

-- build Server Sent Event Application
sseApp :: Text -> TVar SSEChannelMap -> Application -> Application
sseApp endPoint sseChannelMapTVar backupApp req sendResponses = do
    let p = safeHead $ pathInfo req
        safeHead []    = Nothing
        safeHead (a:_) = Just a
        clientIdM = join $ lookup "clientId" $ queryString req
    if p == Just endPoint && isJust clientIdM
        then do
            let cid = fromJust $ join $ (UUID.fromString . Char8.unpack) <$> clientIdM
            c <- newChan
            forkIO $ do
                threadDelay 1000
                writeChan c $ RetryEvent 1000
            atomically $ modifyTVar sseChannelMapTVar (M.alter (const $ Just c) cid)
            eventSourceAppChan c req sendResponses
        else backupApp req sendResponses
#endif

