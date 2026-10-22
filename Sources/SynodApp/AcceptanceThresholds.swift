/// Pass/fail limits of the export acceptance run (`Synod --acceptance`).
///
/// Calibration (Raft, seed 3, ordered, 1920x1080, 60 fps, H.264, 8,880 frames, 92 sampled): the
/// measured PSNR was 42.90 dB at worst (frame 0) with a median of 47.30 dB, and the mean absolute
/// difference was 1.33 at worst (also frame 0, where the title text is sharpest). The limits keep
/// about 5 dB and 0.67 of headroom for encoder and machine differences and must never go below
/// `psnrFloor`.
enum AcceptanceThresholds {
    /// Every sampled video frame must reach this PSNR (dB, 8-bit RGB) against the stage reference.
    static let minPSNR = 38.0
    /// Every sampled video frame must stay under this mean absolute difference (0...255 scale).
    static let maxMAD = 2.0
    /// The frame identity check applies where two neighbouring references differ by less than this PSNR.
    static let distinctRefPSNR = 45.0
    /// The lowest PSNR limit this file may ever carry.
    static let psnrFloor = 34.0
}

/// Pass/fail limits of the GIF frame check (`Synod --gif-check`, run by `--m9`).
extension AcceptanceThresholds {
    /// Each sampled GIF frame against the stage frame drawn at the GIF's size must reach this PSNR (dB).
    /// Calibration (tcp, 640 px, 20 fps, rate 1, 30 samples): worst sampled frame 58.04 dB (45 frames, 31 sampled);
    /// raft (2,961 frames, 32 sampled) 45.22 dB; cassandra (3,622 frames, 32 sampled) 49.39 dB. The limit keeps
    /// about 15 dB of headroom for encoder and machine differences.
    static let gifMinPSNR = 30.0
    /// The lowest `gifMinPSNR` may ever be.
    static let gifPSNRFloor = 28.0
    /// "Closer to its own frame than to its neighbours' wherever the frames differ": only where two
    /// neighbouring stage frames are further apart than this (dB).
    static let gifDistinctRefPSNR = 40.0
}
