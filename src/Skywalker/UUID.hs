{-# LANGUAGE CPP, JavaScriptFFI #-}
module Skywalker.UUID
    (UUID, nil, toString, fromString, generateUUID
    ) where

#if defined(ghcjs_HOST_OS)
import Data.JSString
import Data.Maybe (fromJust)
import Data.UUID.Types

foreign import javascript unsafe "window['generateUUID']()"
    js_generateUUID :: IO JSString

genUUID :: IO String
genUUID = unpack <$> js_generateUUID

#else
import Data.UUID
import qualified Data.UUID.V4 as V4
#endif

generateUUID :: IO UUID
#if defined(ghcjs_HOST_OS)
generateUUID = (fromJust . fromString) <$> genUUID
#else
generateUUID = V4.nextRandom
#endif
