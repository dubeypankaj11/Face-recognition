{-# LANGUAGE BangPatterns #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE MultiParamTypeClasses #-}

-- | Contains everything to train and use a cascade of 'HaarClassifier'.
-- The cascade is composed of 'StrongClassifier's build on 'HaarClassifier's.
-- The 'HaarCascade' is explained in
-- /Viola, Jones: Robust Real-time Object Detection, IJCV 2001/
module Vision.Haar.Cascade (
    -- * Types & constructors
      HaarCascade (..), HaarCascadeStage (..)
    -- * Constants
    , maxFalsePositive, stageMaxFalsePositive, stageMinDetection
    -- * Functions
    , trainHaarCascade, cascadeStats
    -- * Impure utilities
    , saveHaarCascade, loadHaarCascade
    ) where

import Data.List
import Data.Ratio
import System.Random (mkStdGen)

import AI.Learning.AdaBoost (adaBoost)
import AI.Learning.Classifier (
      Classifier (..), Score, StrongClassifier (..), TrainingTest (..)
    )

import Vision.Haar.Classifier (
      HaarClassifier (..), trainHaarClassifier
    )
import Vision.Haar.Window (
      Win, win, windowWidth, windowHeight, randomImagesWindows
    )
import qualified Vision.Image.IntegralImage as II
import Vision.Primitive (Rect (..))

-- | The 'HaarCascade' consists in a set of 'HaarCascadeStage' which will be
-- evaluated in cascade to check an image for an object.
newtype HaarCascade = HaarCascade {
      hcaStages :: [HaarCascadeStage]
    } deriving (Show, Read)

-- | An 'HaarCascadeStage' is 'StrongClassifier' (composed of 'HaarClassifier's)
-- trained with the 'adaBoost' algorithm associated with a threshold on the
-- detection score which enable the cascade trainer to adjust the detection
-- rate. First stages of the cascade have high false positive rate but very low
-- non-detection rate.
data HaarCascadeStage = HaarCascadeStage {
      hcsClassifier :: !(StrongClassifier HaarClassifier)
    , hcsThreshold :: !Score
    } deriving (Show, Read)

maxFalsePositive, stageMaxFalsePositive, stageMinDetection :: Rational
maxFalsePositive = 0.00002
stageMaxFalsePositive = 0.50
stageMinDetection = 0.99

-- | The 'HaarCascade' is able to classify a part of an image using its 
-- iteration window by evaluating each stage in cascade.
-- The classifier score is 
instance Classifier HaarCascade Win Bool where
    HaarCascade stages `cClassScore` window =
        go stages 0 0
      where
        go []     !sumScores !nStages = (True, sumScores / nStages)
        go (s:ss) !sumScores !nStages =
            let (!valid, score) = s `cClassScore` window
                nStages' = nStages + 1
            in if valid
                  then go ss (score + sumScores) nStages'
                  else (False, 1 - ((sumScores + 1 - score) / nStages'))

-- | The 'HaarCascadeStage' validate the window if the score of the 
-- 'StrongClassifier' is greater than the threshold.
instance Classifier HaarCascadeStage Win Bool where
    HaarCascadeStage sc thres `cClassScore` window =
        let !stageScore = objectConfidence sc window
        in if stageScore >= thres
              then (True, stageScore / scTotalWeights sc)
              else (False, 1 - (stageScore / scTotalWeights sc))
    {-# INLINE cClassScore #-}

-- | Returns the confidence score that the strong classifier gives about the 
-- object nature of a window. The confidence score is the sum of the weight
-- of weak classifiers which validate the window.
objectConfidence :: StrongClassifier HaarClassifier -> Win -> Score
objectConfidence (StrongClassifier cs _) window =
    sum [ w | (c, w) <- cs, c `cClass` window ]

-- | Trains an 'HaarCascade' using a set of valid and invalid images.
-- Adds new stages to the cascade until 'maxFalsePositive' is not obtained.
trainHaarCascade :: -- | Valid integral images (identity and squared).
                    [(II.IntegralImage, II.IntegralImage)]
                    -- | Invalid integral images.
                 -> [(II.IntegralImage, II.IntegralImage)] -> HaarCascade
trainHaarCascade validImgs invalidImgs =
    HaarCascade stages
  where
    stages = trainCascade 0 1.0

    -- Trains the cascade by adding a new stage until the false detection rate
    -- is too high.
    trainCascade nStages falsePositive =
        let -- Selects a new set of invalid tests which are incorrectly detected
            -- as faces by the current cascade.
            currCascade = HaarCascade (take nStages stages)
            isFalsePositive = (currCascade `cClass`) . tTest
            !invalids =
                take nValid $ filter isFalsePositive $ invalidsGen nStages

            -- Trains the new stage with the set of tests.
            sc = tail $ adaBoost (invalids ++ valids) trainHaarClassifier
            (!stage, !stageFalsePositive) = trainStage sc invalids

            falsePositive' = falsePositive * stageFalsePositive
        in if falsePositive' > maxFalsePositive
              -- Add a new stage to the cascade if the false detection rate is
              -- too high.
              then stage : trainCascade (nStages + 1) falsePositive'
              else []

    -- Trains a stage of the cascade by adding a new weak classifier to the 
    -- the stage\'s 'StrongClassifier' until the stage meets the required level
    -- of false detection.
    -- For each new weak classifier, decrease the threshold of the 
    -- 'StrongClassifier' until the stage reaches the minimum level of 
    -- detection.
    trainStage ~(!sc:scs) invalids =
        let -- Valid faces scores, sorted, descending.
            scores = reverse $ sort $ map (objectConfidence sc . tTest) valids

            groupedScores = [ (head s, length s) | s <- group scores ]

            -- Number of not detected valid tests for each threshold.
            thresholdsNotDetected =
                -- Starts with an infinite threshold so each face is not 
                -- detected.
                let infinity = 1/0
                in scanl step (infinity, nValid) groupedScores
            step (_, !nNotDetected) (!thres, !nDetected) =
                (thres, nNotDetected - nDetected)

            -- Detection rates (score between 0 and 1) for each threshold.
            thresholdsRate = [ (thres, rate)
                | (thres, nNotDetected) <- thresholdsNotDetected
                , let rate = integer (nValid - nNotDetected) % integer nValid
                ]

            -- Find the first threshold which reaches the required minimum
            -- detection rate.
            Just (!threshold, _) =
                find ((>= stageMinDetection) . snd) thresholdsRate

            stage = HaarCascadeStage sc threshold

            nFalsePositive =
                length $ filter ((stage `cClass`) . tTest) invalids
            falsePositive = integer nFalsePositive % integer nValid
        in if falsePositive > stageMaxFalsePositive
              -- Add a new weak classifier if the false positive rate is too
              -- high.
              then trainStage scs invalids
              else (stage, falsePositive)

    nValid = length validImgs

    -- Initialises a window for each valid image.
    valids = [ TrainingTest w True | (ii, sqii) <- validImgs
        , let !w = win (Rect 0 0 windowWidth windowHeight) ii sqii
        ]

    -- Returns a generator of random 'TrainingImage' from the non object
    -- images and the number of images and different random windows.
    -- The rand parameter imposes to the function to not be a CAF, which would
    -- make a memory overflow.
    invalidsGen rand = [ TrainingTest w False
        | !w <- randomImagesWindows (mkStdGen rand) invalidImgs
        ]

-- | Gives the statistics (detection rate, false positive rate) of an
-- 'HaarCascade'.
cascadeStats :: HaarCascade -> [Win] -> [Win] -> (Score, Score)
cascadeStats cascade valids invalids = 
    let (nValid, nInvalid) = (length valids, length invalids)
        nDetected = length $ filter (cascade `cClass`) valids
        nFalsePositive = length $ filter (cascade `cClass`) invalids
        detectionRate = double nDetected / double nValid
        falsePositiveRate = double nFalsePositive / double nInvalid
    in (detectionRate, falsePositiveRate)

-- | Saves a trained 'HaarCascade'.
saveHaarCascade :: FilePath -> HaarCascade -> IO ()
saveHaarCascade path = writeFile path . show

-- | Loads a trained 'HaarCascade'.
loadHaarCascade :: FilePath -> IO HaarCascade
loadHaarCascade path = read `fmap` readFile path

integer :: Integral a => a -> Integer
integer = fromIntegral
double :: Integral a => a -> Double
double = fromIntegral