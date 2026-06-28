import { buildModule } from "@nomicfoundation/hardhat-ignition/modules";

export default buildModule("AIJudgeModule", (m) => {
  const aiJudge = m.contract("AIJudge");

  return { aiJudge };
});
