{-# LANGUAGE FlexibleContexts, ScopedTypeVariables, MultiParamTypeClasses, FlexibleInstances #-}

{-| Various utiliy signal processing functions -}
module SDR.Util (
    -- * Classes
    Mult,
    mult,

    -- * Conversion to Floating Point
    interleavedIQUnsigned256ToFloat,
    interleavedIQUnsignedByteToFloat,
    interleavedIQUnsignedByteToFloatSSE,
    interleavedIQUnsignedByteToFloatAVX,
    interleavedIQUnsignedByteToFloatFast,

    interleavedIQSigned2048ToFloat,
    interleavedIQSignedWordToFloat,
    interleavedIQSignedWordToFloatSSE,
    interleavedIQSignedWordToFloatAVX,

    complexFloatToInterleavedIQSigned2048,
    complexFloatToInterleavedIQSignedWord,

    -- * Scaling
    scaleC,
    scaleCSSE,
    scaleCAVX,
    scaleFast,

    -- * Misc Utils
    cplxMap,
    quarterBandUp,
    streamString,
    streamRandom
    ) where

import           Foreign.C.Types
import           Data.Complex
import           Data.Vector.Generic          as VG   hiding ((++))
import qualified Data.Vector.Generic.Mutable  as VGM
import           Data.Vector.Storable         as VS   hiding ((++))
import           Data.Vector.Storable.Mutable as VSM  
import           Control.Monad.Primitive
import           Unsafe.Coerce
import           Foreign.Ptr
import           System.IO.Unsafe
import           Foreign.Storable.Complex
import           Control.Monad
import qualified System.Random.MWC as R
import           Data.Bits
import           Pipes
import qualified Pipes.Prelude as P
import           Data.Word

import           SDR.CPUID
import           SDR.VectorUtils

-- | A class for things that can be multiplied by a scalar.
class Mult a b where
    mult :: a -> b -> a

instance (Num a) => Mult a a where
    mult = (*)

instance (Num a) => Mult (Complex a) a where
    mult (x :+ y) z = (x * z) :+ (y * z)

-- | Create a vector of complex floating samples from a vector of interleaved I Q components. Each input element ranges from 0 to 255. This is the format that RTLSDR devices use.
{-# INLINE interleavedIQUnsigned256ToFloat #-}
interleavedIQUnsigned256ToFloat :: (Num a, Integral a, Num b, Fractional b, VG.Vector v1 a, VG.Vector v2 (Complex b)) => v1 a -> v2 (Complex b)
interleavedIQUnsigned256ToFloat input = VG.generate (VG.length input `quot` 2) convert
    where
    {-# INLINE convert #-}
    convert idx  = convert' (input `VG.unsafeIndex` (2 * idx)) :+ convert' (input `VG.unsafeIndex` (2 * idx + 1))
    {-# INLINE convert' #-}
    convert' val = (fromIntegral val - 128) / 128

foreign import ccall unsafe "convertC"
    convertC_c :: CInt -> Ptr CUChar -> Ptr CFloat -> IO ()

-- | Same as `interleavedIQUnsigned256ToFloat` but written in C and specialized for unsigned byte inputs and Float outputs.
interleavedIQUnsignedByteToFloat :: VS.Vector CUChar -> VS.Vector (Complex Float)
interleavedIQUnsignedByteToFloat inBuf = unsafePerformIO $ do
    outBuf <- VGM.new $ VG.length inBuf `quot` 2
    VS.unsafeWith inBuf $ \iPtr -> 
        VSM.unsafeWith (unsafeCoerce outBuf) $ \oPtr -> 
            convertC_c (fromIntegral $ VG.length inBuf) iPtr oPtr
    VG.freeze outBuf

foreign import ccall unsafe "convertCSSE"
    convertCSSE_c :: CInt -> Ptr CUChar -> Ptr CFloat -> IO ()

-- | Same as `interleavedIQUnsigned256ToFloat` but written in C using SSE intrinsics and specialized for unsigned byte inputs and Float outputs.
interleavedIQUnsignedByteToFloatSSE :: VS.Vector CUChar -> VS.Vector (Complex Float)
interleavedIQUnsignedByteToFloatSSE inBuf = unsafePerformIO $ do
    outBuf <- VGM.new $ VG.length inBuf `quot` 2
    VS.unsafeWith inBuf $ \iPtr -> 
        VSM.unsafeWith (unsafeCoerce outBuf) $ \oPtr -> 
            convertCSSE_c (fromIntegral $ VG.length inBuf) iPtr oPtr
    VG.freeze outBuf

foreign import ccall unsafe "convertCAVX"
    convertCAVX_c :: CInt -> Ptr CUChar -> Ptr CFloat -> IO ()

-- | Same as `interleavedIQUnsigned256ToFloat` but written in C using AVX intrinsics and specialized for unsigned byte inputs and Float outputs.
interleavedIQUnsignedByteToFloatAVX :: VS.Vector CUChar -> VS.Vector (Complex Float)
interleavedIQUnsignedByteToFloatAVX inBuf = unsafePerformIO $ do
    outBuf <- VGM.new $ VG.length inBuf `quot` 2
    VS.unsafeWith inBuf $ \iPtr -> 
        VSM.unsafeWith (unsafeCoerce outBuf) $ \oPtr -> 
            convertCAVX_c (fromIntegral $ VG.length inBuf) iPtr oPtr
    VG.freeze outBuf

-- | Same as `interleavedIQUnsigned256ToFloat` but uses the fastest SIMD instruction set your processor supports and specialized for unsigned byte inputs and Float outputs.
interleavedIQUnsignedByteToFloatFast :: CPUInfo -> VS.Vector CUChar -> VS.Vector (Complex Float)
interleavedIQUnsignedByteToFloatFast info = featureSelect info interleavedIQUnsignedByteToFloat [(hasAVX2, interleavedIQUnsignedByteToFloatAVX), (hasSSE42, interleavedIQUnsignedByteToFloatSSE)]

-- | Create a vector of complex float samples from a vector of interleaved I Q components. Each input element ranges from -2048 to 2047. This is the format that the BladeRF uses.
{-# INLINE interleavedIQSigned2048ToFloat #-}
interleavedIQSigned2048ToFloat :: (Num a, Integral a, Num b, Fractional b, VG.Vector v1 a, VG.Vector v2 (Complex b)) => v1 a -> v2 (Complex b)
interleavedIQSigned2048ToFloat input = VG.generate (VG.length input `quot` 2) convert
    where
    {-# INLINE convert #-}
    convert idx  = convert' (input `VG.unsafeIndex` (2 * idx)) :+ convert' (input `VG.unsafeIndex` (2 * idx + 1))
    {-# INLINE convert' #-}
    convert' val = fromIntegral val / 2048

foreign import ccall unsafe "convertCBladeRF"
    convertCBladeRF_c :: CInt -> Ptr CShort -> Ptr CFloat -> IO ()

-- | Same as `interleavedIQUnsigned256ToFloat` but written in C and specialized for unsigned byte inputs and Float outputs.
interleavedIQSignedWordToFloat :: VS.Vector CShort -> VS.Vector (Complex Float)
interleavedIQSignedWordToFloat inBuf = unsafePerformIO $ do
    outBuf <- VGM.new $ VG.length inBuf `quot` 2
    VS.unsafeWith inBuf $ \iPtr -> 
        VSM.unsafeWith (unsafeCoerce outBuf) $ \oPtr -> 
            convertCBladeRF_c (fromIntegral $ VG.length inBuf) iPtr oPtr
    VG.freeze outBuf

foreign import ccall unsafe "convertCSSEBladeRF"
    convertCSSEBladeRF_c :: CInt -> Ptr CShort -> Ptr CFloat -> IO ()

-- | Same as `interleavedIQUnsigned256ToFloat` but written in C using SSE intrinsics and specialized for unsigned byte inputs and Float outputs.
interleavedIQSignedWordToFloatSSE :: VS.Vector CShort -> VS.Vector (Complex Float)
interleavedIQSignedWordToFloatSSE inBuf = unsafePerformIO $ do
    outBuf <- VGM.new $ VG.length inBuf `quot` 2
    VS.unsafeWith inBuf $ \iPtr -> 
        VSM.unsafeWith (unsafeCoerce outBuf) $ \oPtr -> 
            convertCSSEBladeRF_c (fromIntegral $ VG.length inBuf) iPtr oPtr
    VG.freeze outBuf

foreign import ccall unsafe "convertCAVXBladeRF"
    convertCAVXBladeRF_c :: CInt -> Ptr CShort -> Ptr CFloat -> IO ()

-- | Same as `interleavedIQUnsigned256ToFloat` but written in C using AVX intrinsics and specialized for unsigned byte inputs and Float outputs.
interleavedIQSignedWordToFloatAVX :: VS.Vector CShort -> VS.Vector (Complex Float)
interleavedIQSignedWordToFloatAVX inBuf = unsafePerformIO $ do
    outBuf <- VGM.new $ VG.length inBuf `quot` 2
    VS.unsafeWith inBuf $ \iPtr -> 
        VSM.unsafeWith (unsafeCoerce outBuf) $ \oPtr -> 
            convertCAVXBladeRF_c (fromIntegral $ VG.length inBuf) iPtr oPtr
    VG.freeze outBuf

complexFloatToInterleavedIQSigned2048 :: (Integral b, RealFrac a, VG.Vector v1 (Complex a), VG.Vector v2 b) => v1 (Complex a) -> v2 b
complexFloatToInterleavedIQSigned2048 input = VG.generate (VG.length input * 2) convert
    where
    {-# INLINE convert #-}
    convert idx  
        | even idx = convert' $ realPart (input `VG.unsafeIndex` (idx `quot` 2))
        | odd  idx = convert' $ imagPart (input `VG.unsafeIndex` (idx `quot` 2))
    {-# INLINE convert' #-}
    convert' val = round $ val * 2048

foreign import ccall unsafe "convertBladeRFTransmit"
    convertBladeRFTransmit_c :: CInt -> Ptr CFloat -> Ptr CShort -> IO ()

complexFloatToInterleavedIQSignedWord :: VS.Vector (Complex Float) -> VS.Vector CShort
complexFloatToInterleavedIQSignedWord inBuf = unsafePerformIO $ do
    outBuf <- VGM.new $ VG.length inBuf * 2
    VS.unsafeWith (unsafeCoerce inBuf) $ \iPtr -> 
        VSM.unsafeWith outBuf $ \oPtr -> 
            convertBladeRFTransmit_c (fromIntegral $ VG.length inBuf * 2) iPtr oPtr
    VG.freeze outBuf
    
-- | Scaling
foreign import ccall unsafe "scale"
    scale_c :: CInt -> CFloat -> Ptr CFloat -> Ptr CFloat -> IO ()

-- | Scale a vector, written in C
scaleC :: Float                      -- ^ Scale factor
       -> VS.Vector Float            -- ^ Input vector
       -> VS.MVector RealWorld Float -- ^ Output vector
       -> IO ()
scaleC factor inBuf outBuf = 
    VS.unsafeWith (unsafeCoerce inBuf) $ \iPtr -> 
        VS.unsafeWith (unsafeCoerce outBuf) $ \oPtr -> 
            scale_c (fromIntegral (VG.length inBuf)) (unsafeCoerce factor) iPtr oPtr

foreign import ccall unsafe "scaleSSE"
    scaleSSE_c :: CInt -> CFloat -> Ptr CFloat -> Ptr CFloat-> IO ()

-- | Scale a vector, written in C using SSE intrinsics
scaleCSSE :: Float                      -- ^ Scale factor
          -> VS.Vector Float            -- ^ Input vector
          -> VS.MVector RealWorld Float -- ^ Output vector
          -> IO ()
scaleCSSE factor inBuf outBuf = 
    VS.unsafeWith (unsafeCoerce inBuf) $ \iPtr -> 
        VS.unsafeWith (unsafeCoerce outBuf) $ \oPtr -> 
            scaleSSE_c (fromIntegral (VG.length inBuf)) (unsafeCoerce factor) iPtr oPtr

foreign import ccall unsafe "scaleAVX"
    scaleAVX_c :: CInt -> CFloat -> Ptr CFloat -> Ptr CFloat -> IO ()

-- | Scale a vector, written in C using AVX intrinsics
scaleCAVX :: Float                      -- ^ Scale factor
          -> VS.Vector Float            -- ^ Input vector
          -> VS.MVector RealWorld Float -- ^ Output vector
          -> IO ()
scaleCAVX factor inBuf outBuf = 
    VS.unsafeWith (unsafeCoerce inBuf) $ \iPtr -> 
        VS.unsafeWith (unsafeCoerce outBuf) $ \oPtr -> 
            scaleAVX_c (fromIntegral (VG.length inBuf)) (unsafeCoerce factor) iPtr oPtr

-- | Scale a vector. Uses the fastest SIMD instruction set your processor supports.
scaleFast :: CPUInfo -> Float -> VS.Vector Float -> VS.MVector RealWorld Float -> IO ()
scaleFast info = featureSelect info scaleC [(hasAVX, scaleCAVX), (hasSSE42, scaleCSSE)]

-- | Apply a function to both parts of a complex number
cplxMap :: (a -> b)  -- ^ The function
        -> Complex a -- ^ Input complex number
        -> Complex b -- ^ Output complex number
cplxMap f (x :+ y) = f x :+ f y

-- | Multiplication by this vector shifts all frequencies up by 1/4 of the sampling frequency
quarterBandUp :: (VG.Vector v (Complex n), Num n) 
              => Int -- ^ The length of the Vector
              -> v (Complex n)
quarterBandUp size = VG.generate size func
    where
    func idx 
        | m == 0 = 1    :+ 0
        | m == 1 = 0    :+ 1
        | m == 2 = (-1) :+ 0
        | m == 3 = 0    :+ (-1)
        where
        m = idx `mod` 4

streamString :: forall m b. (FiniteBits b, Monad m) => [b] -> Int -> Producer (VS.Vector Float) m ()
streamString str size = P.unfoldr (return . Right . func) (str, 0)
    where
    bitsPerChar = finiteBitSize (undefined :: b)
    toFloat :: Bool -> Float
    toFloat x   = if x then 1 else (-1)
    func = vUnfoldr size funcy 
        where
        funcy ([], offsetChar) = funcy (str, 0)
        funcy (rem@(x:xs), offsetChar)
            | offsetChar == bitsPerChar = funcy (xs, 0)
            | otherwise                 = (toFloat $ testBit x offsetChar, (rem, offsetChar + 1))

streamRandom :: forall m. PrimMonad m => Int -> Producer (VS.Vector Float) m ()
streamRandom size = do
    gen   <- lift $ R.create 
    start <- lift $ R.uniform gen
    P.unfoldr (liftM Right . (func gen)) (start, 0)
    where
    toFloat :: Bool -> Float
    toFloat x   = if x then 1 else (-1)
    func :: R.Gen (PrimState m) -> (Word64, Int) -> m (VS.Vector Float, (Word64, Int))
    func gen = vUnfoldrM size funcy 
        where
        funcy (current, offset) = do
            let res =  toFloat $ testBit current offset
            if offset == 63 then do
                current' <- R.uniform gen
                return (res, (current', 0))
            else return (res, (current, offset+1))
