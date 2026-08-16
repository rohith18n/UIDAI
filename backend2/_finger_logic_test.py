"""Compare OLD vs NEW finger-counting logic on real saved hand images."""
import os, glob, math, cv2
import mediapipe as mp

mp_hands = mp.solutions.hands


def landmarks_for(path):
    img = cv2.imread(path)
    if img is None:
        return None
    rgb = cv2.cvtColor(img, cv2.COLOR_BGR2RGB)
    with mp_hands.Hands(static_image_mode=True, max_num_hands=1,
                        min_detection_confidence=0.5) as hands:
        res = hands.process(rgb)
    if not res.multi_hand_landmarks:
        return None
    lm = res.multi_hand_landmarks[0].landmark
    handed = "Right"
    if res.multi_handedness:
        handed = res.multi_handedness[0].classification[0].label
    return lm, handed


def count_old(lm, handed):
    tips = [4, 8, 12, 16, 20]
    pips = [3, 6, 10, 14, 18]
    count = 0
    if lm[4].x < lm[3].x:            # thumb (original)
        count += 1
    for tip, pip in zip(tips[1:], pips[1:]):
        if lm[tip].y < lm[pip].y:
            count += 1
    return count


def count_new(lm, handed):
    def d(a, b):
        return math.hypot(lm[a].x - lm[b].x, lm[a].y - lm[b].y)
    wrist = 0
    count = 0
    # 4 fingers: tip farther from wrist than its PIP joint -> extended (rotation-invariant)
    for tip, pip in zip([8, 12, 16, 20], [6, 10, 14, 18]):
        if d(tip, wrist) > d(pip, wrist):
            count += 1
    # thumb: tip farther from index-MCP(5) than the IP joint(3) -> extended
    if d(4, 5) > d(3, 5):
        count += 1
    return count


imgs = sorted(glob.glob("uploads/20260531_1913*_fp.jpg") +
              glob.glob("uploads/20260531_1914*_fp.jpg") +
              glob.glob("uploads/20260531_1915*_fp.jpg"))

print(f"{'image':<32} {'hand':<6} {'OLD':<4} {'NEW':<4}")
print("-" * 50)
hand_imgs = 0
for p in imgs:
    r = landmarks_for(p)
    if r is None:
        continue                      # not a hand (or no detection)
    lm, handed = r
    hand_imgs += 1
    print(f"{os.path.basename(p):<32} {handed:<6} {count_old(lm, handed):<4} {count_new(lm, handed):<4}")
print(f"\nHands detected in {hand_imgs} images.")
