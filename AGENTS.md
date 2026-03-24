# AGENTS.md — Bread Porosity iOS App

## 1. Mission

Build a **production-quality iOS app** that estimates bread porosity from images.

The app must:
- Run fully **on-device**
- Allow user to:
  - take a photo (camera)
  - or select from photo library
- Output: porosity = (air-hole area) / (ROI area) binary mask image
  - overlay image for verification

This is a **computer vision + mobile engineering problem**, not a pure UI or ML problem.

---

## 2. Product Definition

### Porosity (MVP Definition)

Porosity is defined as:

    porosity = (# pixels classified as pore) / (# pixels in ROI)

Where:
- "pore" = darker void regions in bread crumb
- ROI = selected or full image area

Optional metrics:
- pore count (connected components)
- average pore size
- pore size distribution

---

## 3. Core Constraints

### MUST DO
- Use **Swift + SwiftUI**
- Use **on-device processing only**
- Use **classical CV methods first**
- Produce **runnable Xcode project code**

### MUST NOT DO
- Do NOT start with CoreML / deep learning
- Do NOT build backend services
- Do NOT overengineer architecture
- Do NOT produce pseudocode-only outputs

---

## 4. System Architecture

### High-Level Layers
UI Layer (SwiftUI)
↓
Image Input Layer
↓
Image Processing Pipeline
↓
Metrics Computation ↓
Visualization Layer

---

### Modules

#### 1. UI Layer
- SwiftUI Views
- Responsibilities:
  - image selection (camera / library)
  - ROI selection (optional)
  - display results

#### 2. Image Input Layer
- Convert `UIImage` → processing format
- Handle orientation / resizing

#### 3. Image Processing Pipeline (CORE)
Must be modular and testable

Pipeline stages:

1. Preprocessing
   - grayscale conversion
   - normalization (lighting correction)

2. Segmentation
   - thresholding (Otsu / adaptive)
   - produce binary mask

3. Morphology
   - remove noise (open/close)
   - fill small holes if needed

4. Connected Components
   - label pores
   - filter by minimum area

#### 4. Metrics Module
- Compute:
  - porosity ratio
  - pore count
  - area statistics

#### 5. Visualization Module
- Generate:
  - binary mask image
  - overlay image (mask on original)

---

## 5. Data Flow
Camera / Photo Library
↓
UIImage
↓
Preprocessing
↓
Segmentation (binary mask)
↓
Morphology cleanup
↓
Connected components
↓
Metrics computation
↓
UI rendering (mask + overlay + stats)

---

## 6. Image Processing Guidelines

### Preferred Techniques

- Grayscale conversion
- Histogram normalization or CLAHE
- Otsu thresholding OR adaptive thresholding
- Morphological operations:
  - erosion / dilation
  - opening / closing
- Connected component analysis

### Parameters (must be configurable)

- threshold method
- minimum pore size
- morphology kernel size
- ROI selection

---

## 7. Known Challenges & Mitigation

### 1. Uneven Lighting
Problem:
- causes incorrect thresholding

Mitigation:
- adaptive thresholding
- local normalization

---

### 2. Crust vs Crumb Confusion
Problem:
- crust may be classified as pore

Mitigation:
- exclude outer border
- color/texture filtering
- ROI cropping

---

### 3. Noise / Small Artifacts
Problem:
- tiny dark pixels counted as pores

Mitigation:
- minimum area threshold
- morphology cleanup

---

### 4. Shadows
Problem:
- shadows falsely detected as pores

Mitigation:
- normalization
- avoid global threshold only

---

## 8. Development Strategy

### Phase 1 — Core CV Engine (NO UI FOCUS)
- Input: UIImage
- Output:
  - porosity
  - mask
  - overlay
- Must be testable independently

---

### Phase 2 — Basic UI
- Image picker (camera + library)
- Display:
  - original
  - mask
  - overlay
  - porosity value

---

### Phase 3 — Refinement
- ROI cropping
- parameter tuning UI
- performance optimization

---

### Phase 4 — Hardening
- edge-case handling
- error handling
- testing

---

## 9. Coding Principles

### General
- Keep code **modular**
- Avoid monolithic functions
- Prefer **pure functions** in processing pipeline

### Swift-Specific
- Use value types where appropriate
- Keep UIKit bridging minimal
- Use SwiftUI idioms for UI

---

## 10. Output Expectations (Codex Behavior)

When generating code, you MUST:

- Produce **runnable Swift code**
- Include:
  - file structure
  - imports
  - types
  - functions
- Avoid placeholders like:
  - "implement this later"
- Make reasonable assumptions instead of blocking

---

## 11. Iteration Rules

When uncertain:
- Choose a **simple, robust approach**
- Document the assumption
- Proceed

When improving:
- Do NOT rewrite everything
- Modify incrementally

---

## 12. Definition of Done

The project is successful if:

- App runs in Xcode
- User can:
  - take or upload photo
- App outputs:
  - porosity %
  - mask image
  - overlay image
- Mask visually aligns with pores

---

## 13. Future Extensions (NOT MVP)

- Grid mode (multiple samples)
- ML-based segmentation
- Calibration with physical measurements
- Batch processing

---

## 14. Anti-Patterns (Avoid)

- Jumping to deep learning prematurely
- Overcomplicated architecture
- Hardcoded magic thresholds
- UI-first development before CV core
- Ignoring visualization/debugging

---

## 15. Summary for Agent

You are building:

→ A **mobile CV application**
→ With **explainable image processing**
→ That produces **quantitative + visual outputs**

Priority order:

1. Correctness of CV pipeline
2. Interpretability (mask matches reality)
3. Simplicity
4. UI polish

Do not sacrifice (1) and (2) for anything else.
