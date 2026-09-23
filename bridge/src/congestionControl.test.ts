import { CongestionControl } from "./congestionControl.js";
// Congestion can't be reproduced over localhost (the socket drains instantly),
// so the control law is exercised directly. The host call fails harmlessly
// against a nonexistent socket, which is what we want here.
const cc = new CongestionControl("/tmp/nonexistent-vphone.sock", "vm", {
  min: 1_000_000,
  max: 12_000_000,
  start: 12_000_000,
  backlogBytes: 48_000,
});

const mbps = () => (cc.bitrate / 1e6).toFixed(2);

console.log("start:", mbps(), "(expect 12.00)");

cc.decide(true);
console.log("congested:", mbps(), "(expect 8.40)");

cc.decide(true);
console.log("congested:", mbps(), "(expect 5.88)");

// Congestion last hit at 8.4, so under 85% of that (7.14) is headroom already
// proven: jump straight there in one 25% step instead of creeping for three
// seconds, then creep once we're near the rate that actually broke.
for (let i = 1; i <= 9; i++) {
  cc.decide(false);
  console.log(`clean ${i}:`, mbps());
}
console.log("(expect 7.35 immediately, then +1Mbps every 3rd tick: 8.35 at 4, 9.35 at 7)");
console.log("(the old flat climb was still at 6.88 on tick 3 and 8.88 on tick 9)");

// A link that stays clean at the ceiling should not be capped there forever.
const recovered = new CongestionControl("/tmp/nonexistent-vphone.sock", "vm", {
  min: 1_000_000, max: 12_000_000, start: 6_000_000, backlogBytes: 48_000,
});
recovered.decide(true); // ceiling drops to 6Mbps, rate to 4.2
for (let i = 0; i < 12; i++) recovered.decide(false);
console.log(
  "ceiling follows a link that improved:",
  (recovered.bitrate / 1e6).toFixed(2), "(expect above the 6.00 it broke at)"
);
