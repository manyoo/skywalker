{-# LANGUAGE CPP, TypeFamilies, FlexibleContexts, UndecidableInstances, OverloadedStrings #-}
module Skywalker.PubSub
    (Subscribable(..), SubMessage(..),
#if !defined(ghcjs_HOST_OS)
    ChannelBuilder(..), buildChannel
#endif
    ) where

import Data.Map (Map)
import qualified Data.Map as Map
import Data.Default

import Control.Concurrent.STM

import Skywalker.App
import Skywalker.JSON

#if !defined(ghcjs_HOST_OS)
import Control.Monad.State
import Control.Monad.Reader
import Control.Monad.Trans

import Data.Maybe

import Network.WebSockets
#endif

-- Subscribable defines the class for all data models that can be used in
-- a channel
class Subscribable m where
    type SubModelID m :: *
    subscribeModelId :: m -> SubModelID m

-- the possible messages/actions on the data model of that channel
data Subscribable m => SubMessage m = SMNewInstance m
                                    | SMNewInstances [m]
                                    | SMDelInstance m
                                    | SMDelInstances (SubModelID m)
                                    | SMUpdateInstance m
                                    | SMDummy -- just used for return of cbSubscribe
                                              -- because it's not actually used

instance (Subscribable m, ToJSON m, ToJSON (SubModelID m)) => ToJSON (SubMessage m) where
    toJSON (SMNewInstance m)    = object ["cmd" .= ("NewInstance" :: String), "value" .= m]
    toJSON (SMNewInstances ms)  = object ["cmd" .= ("NewInstances" :: String), "value" .= ms]
    toJSON (SMDelInstance m)    = object ["cmd" .= ("DelInstance" :: String), "value" .= m]
    toJSON (SMDelInstances i)   = object ["cmd" .= ("DelInstances" :: String), "value" .= i]
    toJSON (SMUpdateInstance m) = object ["cmd" .= ("UpdateInstance" :: String), "value" .= m]
    toJSON SMDummy              = object ["cmd" .= ("Dummy" :: String), "value" .= ("" :: String)]

instance (Subscribable m, FromJSON m, FromJSON (SubModelID m)) => FromJSON (SubMessage m) where
    parseJSON v = do
        let o = toObject v
        c <- o .: "cmd"
        let parseValue "NewInstance"    = SMNewInstance    <$> o .: "value"
            parseValue "NewInstances"   = SMNewInstances   <$> o .: "value"
            parseValue "DelInstance"    = SMDelInstance    <$> o .: "value"
            parseValue "DelInstances"   = SMDelInstances   <$> o .: "value"
            parseValue "UpdateInstance" = SMUpdateInstance <$> o .: "value"
            parseValue "Dummy"          = return SMDummy
        parseValue $ jsonString c

safeHead []    = Nothing
safeHead (x:_) = Just x

getSubModelId :: Subscribable m => SubMessage m -> Maybe (SubModelID m)
getSubModelId (SMNewInstance m)    = Just $ subscribeModelId m
getSubModelId (SMNewInstances ms)  = subscribeModelId <$> safeHead ms
getSubModelId (SMDelInstance m)    = Just $ subscribeModelId m
getSubModelId (SMDelInstances i)   = Just i
getSubModelId (SMUpdateInstance m) = Just $ subscribeModelId m

#if !defined(ghcjs_HOST_OS)
-- the three remote methods to be exposed to the client side
data ChannelBuilder m = ChannelBuilder {
    cbSubscribe   :: SubModelID m -> Server (SubMessage m),
    cbPublish     :: SubMessage m -> Server (),
    cbUnsubscribe :: SubModelID m -> Server ()
    }

-- data structures used for managing the subscription channles and clients

data ClientSubscription m = ClientSubscription {
    csClientId   :: ClientID,
    csSubModelId :: SubModelID m,
    csNonce      :: Int,
    csConnection :: TVar Connection
    }

-- this will store all clients for one channel
newtype ChannelSubscribers m = ChannelSubscribers {
    csClientSubscribers :: Map (ClientID, SubModelID m) (ClientSubscription m)
    }

instance Default (ChannelSubscribers m) where
    def = ChannelSubscribers Map.empty

addClientSubscriber :: (Subscribable m, Ord (SubModelID m)) => ChannelSubscribers m -> ClientSubscription m -> ChannelSubscribers m
addClientSubscriber ch cs = ch { csClientSubscribers = newMap }
    where m = csClientSubscribers ch
          k = (csClientId cs, csSubModelId cs)

          newMap = case Map.lookup k m of
                        Just _ -> m
                        Nothing -> Map.insert k cs m

delClientSubscriber :: (Subscribable m, Ord (SubModelID m)) => ChannelSubscribers m -> ClientID -> SubModelID m -> ChannelSubscribers m
delClientSubscriber ch cid sid = ch { csClientSubscribers = newMap }
    where m = csClientSubscribers ch
          k = (cid, sid)
          newMap = Map.delete k m

findSubscribers :: Eq (SubModelID m) => ChannelSubscribers m -> ClientID -> SubModelID m -> [ClientSubscription m]
findSubscribers ch cid sid = Map.elems $ Map.filter (validSubscriber cid sid) $ csClientSubscribers ch

validSubscriber :: Eq (SubModelID m) => ClientID -> SubModelID m -> ClientSubscription m -> Bool
validSubscriber cid sid cs = csClientId cs /= cid && csSubModelId cs == sid

buildChannel :: (Subscribable m, ToJSON m, ToJSON (SubModelID m), Eq (SubModelID m), Ord (SubModelID m)) => IO (ChannelBuilder m)
buildChannel = do
    channelTVar <- atomically $ newTVar def
    let sub sid = do
            clientIdM <- seClientId <$> ask
            nonceM    <- seCurrentNonce <$> ask
            connVarM  <- ssConnection <$> get
            liftIO $ when (isJust clientIdM && isJust nonceM && isJust connVarM) $ atomically $ do
                let cid    = fromJust clientIdM
                    nonce  = fromJust nonceM
                    conVar = fromJust connVarM
                ch <- readTVar channelTVar
                let cs = ClientSubscription cid sid nonce conVar
                    newCh = addClientSubscriber ch cs
                writeTVar channelTVar newCh

            return SMDummy

        pub msg = do
            clientIdM <- seClientId <$> ask
            connVarM  <- ssConnection <$> get
            let sidM = getSubModelId msg
            when (isJust clientIdM && isJust connVarM && isJust sidM) $ do
                m <- liftIO $ atomically $ readTVar channelTVar
                let css = findSubscribers m (fromJust clientIdM) (fromJust sidM)
                mapM_ (publishToClients msg) css

        unsub sid = do
            clientIdM <- seClientId <$> ask
            liftIO $ when (isJust clientIdM) $ atomically $ do
                ch <- readTVar channelTVar
                let newCh = delClientSubscriber ch (fromJust clientIdM) sid
                writeTVar channelTVar newCh
    return $ ChannelBuilder sub pub unsub

publishToClients :: (Subscribable m, ToJSON m, ToJSON (SubModelID m)) => SubMessage m -> ClientSubscription m -> Server ()
publishToClients msg cs = liftIO (readTVarIO connVar) >>= sendMessageToClient nonce msg
    where nonce = csNonce cs
          connVar = csConnection cs

#endif
