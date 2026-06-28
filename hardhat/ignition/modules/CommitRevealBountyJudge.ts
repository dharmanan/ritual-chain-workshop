import { buildModule } from "@nomicfoundation/hardhat-ignition/modules";

export default buildModule("CommitRevealBountyJudgeModule", (m) => {
  const judge = m.contract("CommitRevealBountyJudge");

  return { judge };
});
