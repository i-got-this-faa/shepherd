import { describe, expect, it } from "bun:test";
import rootPackage from "../package.json";

describe("monorepo workspace", () => {
  it("defines workspaces correctly", () => {
    expect(rootPackage.workspaces).toBeArray();
    expect(rootPackage.workspaces).toContain("apps/*");
    expect(rootPackage.workspaces).toContain("packages/contracts/gen/ts");
    expect(rootPackage.workspaces).toContain("packages/pi/*");
  });
});
