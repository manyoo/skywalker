{-# LANGUAGE CPP #-}
module Skywalker.JSON (
#if defined(ghcjs_HOST_OS)
    module JavaScript.JSON,
    module JavaScript.JSON.Types,
    module JavaScript.JSON.Types.Class,
    module I,
    module JavaScript.JSON.Types.Generic,
    module JavaScript.JSON.Types.Instances,
    module JavaScript.JSON.Types.Internal,
    object, toObject, jsonString,
#else
    module Data.Aeson,
    toObject, jsonString
#endif
  ) where

#if defined(ghcjs_HOST_OS)
import JavaScript.JSON
import JavaScript.JSON.Types
import JavaScript.JSON.Types.Class
import JavaScript.JSON.Types.Generic
import JavaScript.JSON.Types.Instances
import JavaScript.JSON.Types.Internal hiding (object)
import qualified JavaScript.JSON.Types.Internal as I

import Data.JSString


object = I.objectValue . I.object

toObject :: I.Value -> I.Object
toObject v = let v' = I.match v
             in case v' of
                 I.Object o -> o

jsonString :: I.Value -> String
jsonString v = let v' = I.match v
             in case v' of
                 I.String s -> unpack s

#else
import Data.Aeson
import Data.Text (unpack)

toObject :: Value -> Object
toObject (Object v) = v

jsonString :: Value -> String
jsonString (String s) = unpack s
#endif
