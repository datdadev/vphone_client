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

for (let i = 1; i <= 7; i++) {
  cc.decide(false);
  console.log(`clean ${i}:`, mbps());
}
console.log("(expect +1Mbps on every 3rd clean tick: 6.88 at tick 3, 7.88 at 6)");
