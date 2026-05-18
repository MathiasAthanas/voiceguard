# VoiceGuard AI Model Training Plan

This folder is where we will do the next stage of VoiceGuard AI work. The goal is to train our own models using our local datasets so VoiceGuard becomes better at detecting real voices, cloned voices, and suspicious call audio.

We are starting with two datasets:

```text
aiworks\datagroup1
aiworks\datagroup2
```

These datasets contain two important groups:

```text
really_voices  -> original/real human voices
cloned_voices  -> cloned, fake, or generated voices
```

That structure is useful because it gives us the labels we need for supervised training. In simple terms, we can teach a model by showing it examples of real voices and cloned voices until it learns the difference.

## What We Are Trying To Achieve

VoiceGuard already has speaker verification through ECAPA-TDNN. That part checks whether a voice sounds like the enrolled speaker.

The weaker part right now is anti-spoofing. Anti-spoofing means detecting whether the audio is a real person speaking or a cloned/generated voice.

So our first training target should be:

```text
real voice vs cloned voice
```

We should not immediately replace ECAPA-TDNN. Instead, we should add our trained CNN/LSTM model before speaker verification:

```text
call audio
-> CNN/LSTM fake voice detector
-> ECAPA speaker verification
-> final VoiceGuard verdict
```

This gives us two checks:

```text
Is this voice fake?
Is this voice the correct person?
```

That is stronger than relying on only one model.

## What We Found In The Dataset

After scanning the datasets, we found:

```text
Total files:          4949
Real/original files:  2684
Cloned/fake files:    2265
```

File types:

```text
WAV: 4480
MP3: 455
AMR: 14
```

Important quality notes:

```text
Valid readable WAV files: 4005
Unreadable WAV files:    475
Very short WAV files:    7 under 1 second
Tiny/broken files:       74 under 10 KB
```

The dataset is promising, but it is not ready for training yet. Some files are broken, some are too short, and the audio formats are mixed. If we train directly on this without cleaning, the model may learn the wrong things or produce unreliable results.

## Step 1: Create A Clean Dataset Manifest

The first thing we will do is create a manifest file. This is a CSV file that lists every usable audio file and its label.

It will look like this:

```text
path,label,dataset,speaker_id,duration_seconds,sample_rate,channels
```

Example:

```text
aiworks\datagroup1\v01\really_voices\sample.wav,real,datagroup1,v01,8.0,16000,1
aiworks\datagroup1\v01\cloned_voices\sample.wav,cloned,datagroup1,v01,8.0,16000,1
```

This matters because the model training code should not guess what files mean from folder names every time. The manifest becomes the clean source of truth for training, validation, and testing.

## Step 2: Clean And Normalize The Audio

Before training, we will convert the audio into one consistent format:

```text
WAV
mono
16 kHz
16-bit PCM
```

We will remove files that are:

```text
corrupted
unreadable
too short
silent or almost silent
empty
duplicate
not useful for speech training
```

This step is very important. A model is only as good as the data we give it. If bad audio enters training, the model may become inaccurate even if the model architecture is good.

## Step 3: Prepare The Audio Properly Before Training

After basic cleaning, we still need a detailed preparation stage. This is where we turn the raw dataset into training-ready data.

The full preparation flow should be:

```text
raw audio
-> inspect files
-> filter bad files
-> convert format
-> trim silence
-> normalize loudness
-> validate speech content
-> remove duplicates
-> create labels
-> split dataset
-> extract features
-> train model
```

This is not optional. If we skip this stage, the CNN/LSTM may train on noise, silence, broken audio, or duplicated samples. That would make the results unreliable.

### Filtering

We will filter out files that cannot help the model learn.

Examples:

```text
unreadable files
empty files
very short clips
silent clips
clips with almost no speech
corrupted WAV headers
duplicate clips
very noisy clips if they cannot be repaired
```

Filtering makes the dataset smaller, but stronger. It is better to train on fewer clean files than many bad files.

### Audio Normalization

All files should be converted into the same audio format:

```text
16 kHz sample rate
mono channel
WAV format
16-bit PCM
```

This matters because models work best when every sample follows the same format. If one file is 48 kHz stereo and another is 16 kHz mono, the model may learn format differences instead of voice differences.

### Silence Trimming

Many recordings may contain silence at the beginning or end. We should trim long silence so the model focuses on actual speech.

We should not remove all pauses because natural pauses are part of speech, but we should remove useless empty sections.

### Loudness Normalization

Some clips may be loud and others very quiet. We should normalize loudness so the model does not confuse volume with authenticity.

The goal is not to make every file artificially identical. The goal is to remove extreme volume differences that can distract the model.

### Duplicate Detection

If the same audio appears many times, the model can memorize it. That makes training accuracy look good, but real-world performance becomes weak.

We should detect:

```text
exact duplicate files
near-duplicate clips
repeated generated segments
same audio saved in different formats
```

Duplicates should not appear across training and test sets.

## Step 4: Feature Extraction

Feature extraction is the stage where we convert raw audio into a form that CNN and LSTM models can understand.

Raw waveform audio is not always the easiest input for a small custom model. For our first models, we should extract speech features.

Recommended feature:

```text
log-mel spectrogram
```

A log-mel spectrogram is like an image of the voice. It shows how speech energy is distributed across frequencies over time.

The pipeline will look like this:

```text
audio file
-> load audio at 16 kHz
-> split or pad to fixed duration
-> compute mel spectrogram
-> convert to log scale
-> normalize feature values
-> feed into CNN/LSTM
```

We may also experiment with:

```text
MFCC features
delta features
delta-delta features
spectral centroid
zero-crossing rate
chroma features
```

But for the first serious training run, log-mel spectrograms should be the main feature.

### Why Log-Mel Spectrograms Matter

CNN models work well with image-like inputs. A spectrogram gives the CNN a visual pattern of speech.

The CNN can learn:

```text
frequency artifacts
unnatural clone texture
missing natural speech detail
synthetic generation patterns
noise shapes created by voice cloning tools
```

The LSTM can then learn how those patterns change over time.

### Fixed-Length Training Samples

CNN/LSTM models usually need consistent input sizes. So we should create fixed-length training examples, for example:

```text
3 seconds
4 seconds
5 seconds
```

If a clip is longer, we can split it into windows. If it is slightly shorter, we can pad it carefully.

This gives us more training samples while keeping model input consistent.

## Step 5: Split The Dataset Properly

We will divide the dataset into:

```text
training set
validation set
test set
```

Recommended split:

```text
train:      70%
validation: 15%
test:       15%
```

But we must be careful. We should not simply shuffle all clips randomly. If the same speaker appears in both training and testing, the model may look accurate while it is actually memorizing speaker patterns.

So we should split carefully by speaker/session where possible. That gives us a more honest test of whether the model can detect cloned voices in real-world conditions.

## Step 6: Train A CNN Model First

The first model we should train is a CNN.

A CNN works well with spectrograms. A spectrogram is like an image of sound. It shows how the voice frequencies change over time.

The process will be:

```text
audio file
-> log-mel spectrogram
-> CNN
-> real or cloned prediction
```

The CNN will learn patterns such as:

```text
frequency artifacts
unnatural voice texture
missing human speech details
clone-generation noise
spectral patterns that differ from real voices
```

This gives us a strong first baseline.

## Step 7: Train A CNN + LSTM Model

After the CNN baseline, we will train a CNN + LSTM model.

The CNN will still learn the frequency patterns. The LSTM will then study how those patterns change over time.

This is useful because cloned voices may sound normal in one small moment, but become suspicious across several seconds.

The process will be:

```text
audio file
-> log-mel spectrogram sequence
-> CNN feature extractor
-> LSTM temporal model
-> real or cloned prediction
```

The CNN answers:

```text
What does this part of the voice look like?
```

The LSTM answers:

```text
How does the voice behave over time?
```

Together, this may give better fake-voice detection than CNN alone.

## Step 8: Evaluate Results Properly

We will not judge the model only by accuracy. Accuracy can be misleading if the dataset is unbalanced.

We should measure:

```text
accuracy
precision
recall
F1 score
false accept rate
false reject rate
equal error rate
confusion matrix
performance per speaker/session
```

For VoiceGuard, false accepts are especially dangerous. A false accept means a fake/cloned voice was accepted as real. We need to reduce that as much as possible.

## Step 9: Compare Against The Current System

After training, we will compare the new model against the current VoiceGuard backend.

Current system:

```text
ECAPA-TDNN speaker verification
placeholder anti-spoofing
```

Target system:

```text
CNN/LSTM anti-spoofing
ECAPA-TDNN speaker verification
combined final verdict
```

We should only integrate the new model into the live backend after it proves that it improves detection on the test set.

## Will This Give Better Results?

It can give better results, especially for cloned voice detection.

The reason is simple: right now, VoiceGuard is strong at checking speaker similarity, but it does not yet have a fully trained local model that understands the difference between original and cloned voices from our own datasets.

Training on our own real and cloned voice samples can help the system become more localized and more useful for the actual voices and cloning styles we care about.

However, better results are not automatic. We must clean the data, split it correctly, and test honestly. If we skip those steps, the model may look good during training but fail during real calls.

## Our Immediate Next Milestone

The next practical milestone is dataset preparation.

We should build scripts that do this:

```text
scan datagroup1 and datagroup2
detect labels from folder names
check audio duration and readability
convert audio to 16 kHz mono WAV
remove broken or unusable files
trim silence
normalize loudness
remove duplicates
create manifest.csv
create train.csv, validation.csv, and test.csv
extract log-mel spectrogram features
save a dataset summary report
```

Once this is done, we can begin model training with confidence.

## Final Direction

We are not just training a model for experimentation. We are building the next AI layer of VoiceGuard.

The direction is:

```text
clean dataset
train CNN anti-spoofing baseline
train CNN + LSTM temporal model
evaluate both models
choose the stronger model
connect it to the FastAPI backend
use it together with ECAPA-TDNN
improve real-call fake voice detection
```

That is the path that gives VoiceGuard the best chance of becoming more accurate and more valuable in real use.
