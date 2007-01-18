{-# OPTIONS_GHC -fglasgow-exts #-}
-- for unboxed shifts

-----------------------------------------------------------------------------
-- |
-- Module      : Data.Binary.Get
-- Copyright   : Lennart Kolmodin
-- License     : BSD3-style (see LICENSE)
-- 
-- Maintainer  : Lennart Kolmodin <kolmodin@dtek.chalmers.se>
-- Stability   : unstable
-- Portability : Portable. Requires MPTCs
--
-- The Get monad. A monad for efficiently building structures from
-- encoded lazy ByteStrings
--
-----------------------------------------------------------------------------

#if defined(__GLASGOW_HASKELL__)
#include "MachDeps.h"
#endif

module Data.Binary.Get (

    -- * The Get type
      Get
    , runGet

    -- * Parsing
    , skip
    , uncheckedSkip
    , lookAhead
    , uncheckedLookAhead
    , getBytes
    , remaining
    , isEmpty

    -- * Parsing particular types
    , getWord8

    -- ** ByteStrings
    , getByteString
    , getLazyByteString

    -- ** Big-endian reads
    , getWord16be
    , getWord16le
    , getWord32be

    -- ** Little-endian reads
    , getWord32le
    , getWord64be
    , getWord64le

  ) where

import Control.Monad (liftM)

import qualified Data.ByteString as B
import qualified Data.ByteString.Base as B
import qualified Data.ByteString.Lazy as L

import Foreign

#if defined(__GLASGOW_HASKELL__)
import GHC.Base
import GHC.Word
import GHC.Int
#endif

-- | The parse state
data S = S {-# UNPACK #-} !L.ByteString  -- the rest of the input
           {-# UNPACK #-} !Int64        -- bytes read

-- | The Get monad is just a State monad carrying around the input ByteString
newtype Get a = Get { unGet :: S -> (a, S ) }

instance Monad Get where
    return a  = Get (\s -> (a, s))
    m >>= k   = Get (\s -> let (a, s') = unGet m s
		            in unGet (k a) s')
    fail      = failDesc

get :: Get S
get   = Get (\s -> (s, s))

put :: S -> Get ()
put s = Get (\_ -> ((), s))

instance Functor Get where
    fmap f m = Get (\s -> let (a, s') = unGet m s
                           in (f a, s'))

-- | Run the Get monad applies a 'get'-based parser on the input ByteString
runGet :: Get a -> L.ByteString -> a
runGet m str = case unGet m (S str 0) of (a, _) -> a

failDesc :: String -> Get a
failDesc err = do
    S _ bytes <- get
    Get (error (err ++ ". Failed reading at byte position " ++ show bytes))

-- | Skip ahead @n@ bytes. Fails if fewer than @n@ bytes are available.
skip :: Int -> Get ()
skip n = readN n (const ())

-- | Skip ahead @n@ bytes. 
uncheckedSkip :: Int -> Get ()
uncheckedSkip n = do
    S s bytes <- get
    let rest = L.drop (fromIntegral n) s
    put $! S rest (bytes + (fromIntegral n))
    return ()

-- | Get the next @n@ bytes as a lazy ByteString, without consuming them. 
-- Fails if fewer than @n@ bytes are available.
lookAhead :: Int -> Get L.ByteString
lookAhead n = uncheckedLookAhead n >>= takeExactly n

-- | Get the next up to @n@ bytes as a lazy ByteString, without consuming them. 
uncheckedLookAhead :: Int -> Get L.ByteString
uncheckedLookAhead n = do
    S s _ <- get
    return $ L.take (fromIntegral n) s

-- | Get the number of remaining unparsed bytes.
-- Useful for checking whether all input has been consumed.
-- Note that this forces the rest of the input.
remaining :: Get Int64
remaining = do
    S s _ <- get
    return (L.length s)

-- | Test whether all input has been consumed,
-- i.e. there are no remaining unparsed bytes.
isEmpty :: Get Bool
isEmpty = do
    S s _ <- get
    return (L.null s)

------------------------------------------------------------------------
-- Helpers

-- Fail if the ByteString does not have the right size.
takeExactly :: Int -> L.ByteString -> Get L.ByteString
takeExactly n bs 
    | l == n    = return bs
    | otherwise = fail $ concat [ "Data.Binary.Get.takeExactly: Wanted "
                                , show n, " bytes, found ", show l, "." ]
  where l = fromIntegral (L.length bs)
{-# INLINE takeExactly #-}

-- | Pull up to @n@ bytes from the input. 
getBytes :: Int -> Get L.ByteString
getBytes n = do
    S s bytes <- get
    let (consuming, rest) = L.splitAt (fromIntegral n) s
    put $! S rest (bytes + (fromIntegral n))
    return consuming
{-# INLINE getBytes #-}
-- ^ important

-- Pull n bytes from the input, and apply a parser to those bytes,
-- yielding a value
readN :: Int -> (L.ByteString -> a) -> Get a
readN n f = liftM f (getBytes n >>= takeExactly n)
{-# INLINE readN #-}
-- ^ important

------------------------------------------------------------------------

-- | An efficient 'get' method for strict ByteStrings
getByteString :: Int -> Get B.ByteString
getByteString n = readN (fromIntegral n) (B.concat . L.toChunks)
{-# INLINE getByteString #-}

-- | An efficient 'get' method for lazy ByteStrings. Fails if fewer than
-- @n@ bytes are left in the input.
getLazyByteString :: Int -> Get L.ByteString
getLazyByteString n = readN n id
{-# INLINE getLazyByteString #-}

------------------------------------------------------------------------
-- Primtives

-- | Read a Word8 from the monad state
getWord8 :: Get Word8
getWord8 = readN 1 L.head
{-# INLINE getWord8 #-}

-- XXX readN k 

-- | Read a Word16 in big endian format
getWord16be :: Get Word16
getWord16be = do
    w1 <- liftM fromIntegral getWord8
    w2 <- liftM fromIntegral getWord8
    return $! w1 `shiftl_w16` 8 .|. w2
{-# INLINE getWord16be #-}

-- | Read a Word16 in little endian format
getWord16le :: Get Word16
getWord16le = do
    w1 <- liftM fromIntegral getWord8
    w2 <- liftM fromIntegral getWord8
    return $! w2 `shiftl_w16` 8 .|. w1
{-# INLINE getWord16le #-}

-- | Read a Word32 in big endian format
getWord32be :: Get Word32
getWord32be = do
    w1 <- liftM fromIntegral getWord8
    w2 <- liftM fromIntegral getWord8
    w3 <- liftM fromIntegral getWord8
    w4 <- liftM fromIntegral getWord8
    return $! (w1 `shiftl_w32` 24) .|.
              (w2 `shiftl_w32` 16) .|.
              (w3 `shiftl_w32`  8) .|.
              (w4)
{-# INLINE getWord32be #-}

-- | Read a Word32 in little endian format
getWord32le :: Get Word32
getWord32le = do
    w1 <- liftM fromIntegral getWord8
    w2 <- liftM fromIntegral getWord8
    w3 <- liftM fromIntegral getWord8
    w4 <- liftM fromIntegral getWord8
    return $! (w4 `shiftl_w32` 24) .|.
              (w3 `shiftl_w32` 16) .|.
              (w2 `shiftl_w32`  8) .|.
              (w1)
{-# INLINE getWord32le #-}

-- | Read a Word64 in big endian format
getWord64be :: Get Word64
getWord64be = do
    w1 <- liftM fromIntegral getWord8
    w2 <- liftM fromIntegral getWord8
    w3 <- liftM fromIntegral getWord8
    w4 <- liftM fromIntegral getWord8
    w5 <- liftM fromIntegral getWord8
    w6 <- liftM fromIntegral getWord8
    w7 <- liftM fromIntegral getWord8
    w8 <- liftM fromIntegral getWord8
    return $! (w1 `shiftl_w64` 56) .|.
              (w2 `shiftl_w64` 48) .|.
              (w3 `shiftl_w64` 40) .|.
              (w4 `shiftl_w64` 32) .|.
              (w5 `shiftl_w64` 24) .|.
              (w6 `shiftl_w64` 16) .|.
              (w7 `shiftl_w64`  8) .|.
              (w8)
{-# INLINE getWord64be #-}

-- | Read a Word64 in little endian format
getWord64le :: Get Word64
getWord64le = do
    w1 <- liftM fromIntegral getWord8
    w2 <- liftM fromIntegral getWord8
    w3 <- liftM fromIntegral getWord8
    w4 <- liftM fromIntegral getWord8
    w5 <- liftM fromIntegral getWord8
    w6 <- liftM fromIntegral getWord8
    w7 <- liftM fromIntegral getWord8
    w8 <- liftM fromIntegral getWord8
    return $! (w8 `shiftl_w64` 56) .|.
              (w7 `shiftl_w64` 48) .|.
              (w6 `shiftl_w64` 40) .|.
              (w5 `shiftl_w64` 32) .|.
              (w4 `shiftl_w64` 24) .|.
              (w3 `shiftl_w64` 16) .|.
              (w2 `shiftl_w64`  8) .|.
              (w1)
{-# INLINE getWord64le #-}

------------------------------------------------------------------------
-- Unchecked shifts

shiftl_w16 :: Word16 -> Int -> Word16
shiftl_w32 :: Word32 -> Int -> Word32
shiftl_w64 :: Word64 -> Int -> Word64

#if defined(__GLASGOW_HASKELL__)
shiftl_w16 (W16# w) (I# i) = W16# (w `uncheckedShiftL#`   i)
shiftl_w32 (W32# w) (I# i) = W32# (w `uncheckedShiftL#`   i)

#if WORD_SIZE_IN_BITS < 64
shiftl_w64 (W64# w) (I# i) = W64# (w `uncheckedShiftL64#` i)

foreign import ccall unsafe "stg_uncheckedShiftL64"     
    uncheckedShiftL64#     :: Word64# -> Int# -> Word64#
#else
shiftl_w64 (W64# w) (I# i) = W64# (w `uncheckedShiftL#` i)
#endif

#else
shiftl_w16 = shiftL
shiftl_w32 = shiftL
shiftl_w64 = shiftL
#endif
