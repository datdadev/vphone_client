import type { WebSocket } from "ws";
import { sendVPhoneCommand } from "./vphoneSocket.js";

/**
 * Adapts the encoder's bitrate to what the link actually carries.
 *
 * A fixed bitrate fails in both directions: too high and frames queue in the
 * socket until they're dropped (which freezes the picture until a keyframe),
 * too low and the picture is needlessly soft. The bridge runs this because it
 * is the only component that can see the send socket backing up.
 *
 * AIMD, the same shape TCP uses: back off hard on congestion, creep back up
 * when clean. Congestion is cheap to detect here -- `bufferedAmount` growing
 * means the client isn't draining as fast as we're sending.
 */
export class CongestionControl {
  private current: number;
  private cleanTicks = 0;
  /**
   * The rate we were running at when congestion last hit. Below it we're
   * reclaiming throughput the link has already demonstrated; at or above it
   * we're guessing, and guessing wrong is what costs dropped frames.
   */
  private ceiling: number;

  constructor(
    private readonly socketPath: string,
    private readonly vmName: string,
    private readonly opts: {
      min: number;
      max: number;
      start: number;
      /** bufferedAmount above this means the client is falling behind */
      backlogBytes: number;
    }
  ) {
    this.current = opts.start;
    this.ceiling = opts.max;
  }

  get bitrate(): number {
    return this.current;
  }

  /**
   * The control law, kept free of I/O so it can be tested: real congestion
   * can't be reproduced over localhost, where the socket always drains.
   *
   * @returns the new bitrate if it changed, otherwise null
   */
  decide(congested: boolean): number | null {
    const previous = this.current;

    if (congested) {
      // Multiplicative decrease: overshoot costs dropped frames and a visible
      // freeze, so give up throughput quickly and earn it back slowly.
      this.ceiling = this.current;
      this.current = Math.max(this.opts.min, Math.floor(this.current * 0.7));
      this.cleanTicks = 0;
    } else {
      this.cleanTicks++;
      // A flat additive climb is far too slow to undo a multiplicative drop:
      // two congestion events take 12Mbps to 5.9, and +1Mbps every third tick
      // needs ~18s to get back -- 18s of needlessly soft picture on a link
      // that recovered immediately. Well below the rate that actually broke,
      // the headroom is already proven, so take it back in big steps and slow
      // to a creep only near that rate, where being wrong costs something.
      if (this.current < this.ceiling * 0.85) {
        this.current = Math.min(this.opts.max, Math.ceil(this.current * 1.25));
        this.cleanTicks = 0;
      } else if (this.cleanTicks >= 3) {
        this.current = Math.min(this.opts.max, this.current + 1_000_000);
        this.cleanTicks = 0;
        // Sustained quiet at the ceiling means the link itself improved;
        // let it follow, or one bad moment caps us for the whole session.
        this.ceiling = Math.max(this.ceiling, this.current);
      }
    }

    return this.current === previous ? null : this.current;
  }

  /**
   * @param droppedFrames frames the bridge discarded since the last tick
   * @returns the new bitrate if it changed and the host accepted it
   */
  async tick(ws: WebSocket, droppedFrames: number): Promise<number | null> {
    const congested = droppedFrames > 0 || ws.bufferedAmount > this.opts.backlogBytes;
    const previous = this.current;
    const previousCeiling = this.ceiling;
    const target = this.decide(congested);
    if (target === null) return null;

    try {
      await sendVPhoneCommand(this.socketPath, {
        t: "setBitrate",
        bitrate: target,
        vm: this.vmName,
      });
      return target;
    } catch {
      // The host never applied it, so don't pretend we're running at that rate.
      this.current = previous;
      this.ceiling = previousCeiling;
      return null;
    }
  }
}
