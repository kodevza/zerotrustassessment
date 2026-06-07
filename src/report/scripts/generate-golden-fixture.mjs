import { mkdir, readFile, writeFile } from "node:fs/promises";
import path from "node:path";
import { fileURLToPath } from "node:url";

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const reportRoot = path.resolve(__dirname, "..");
const repoRoot = path.resolve(reportRoot, "../..");
const sourcePath = path.resolve(repoRoot, "ZeroTrustReport99/zt-export/ZeroTrustAssessmentReport.json");
const outputPath = path.resolve(reportRoot, "tests/fixtures/zero-trust-report-golden.json");
const visualOutputPath = path.resolve(reportRoot, "tests/fixtures/zero-trust-report-visual.json");

const text = await readFile(sourcePath, "utf8");
const report = JSON.parse(text.replace(/^\uFEFF/, ""));

const sankeyKeys = [
  "OverviewCaMfaAllUsers",
  "OverviewCaDevicesAllUsers",
  "OverviewAuthMethodsPrivilegedUsers",
  "OverviewAuthMethodsAllUsers",
];

const syntheticSankeyData = {
  OverviewAuthMethodsPrivilegedUsers: {
    description: "Golden privileged users authentication methods by phishing resistance.",
    nodes: [
      { source: "Users", target: "Single factor", value: 1 },
      { source: "Users", target: "Phishable", value: 3 },
      { source: "Users", target: "Phish resistant", value: 2 },
      { source: "Phishable", target: "Phone", value: 1 },
      { source: "Phishable", target: "Authenticator", value: 2 },
      { source: "Phish resistant", target: "Passkey", value: 1 },
      { source: "Phish resistant", target: "WHfB", value: 1 },
      { source: "Users", target: "Single factor", value: null },
    ],
  },
  OverviewAuthMethodsAllUsers: {
    description: "Golden all users authentication methods by phishing resistance.",
    nodes: [
      { source: "Users", target: "Single factor", value: 2 },
      { source: "Users", target: "Phishable", value: 5 },
      { source: "Users", target: "Phish resistant", value: 4 },
      { source: "Phishable", target: "Phone", value: 2 },
      { source: "Phishable", target: "Authenticator", value: 3 },
      { source: "Phish resistant", target: "Passkey", value: 2 },
      { source: "Phish resistant", target: "WHfB", value: 2 },
      { source: "Users", target: "Phone", value: 0 },
    ],
  },
  OverviewCaMfaAllUsers: {
    description: "Golden user sign-ins split by Conditional Access and MFA.",
    nodes: [
      { source: "User sign in", target: "No CA applied", value: 2 },
      { source: "User sign in", target: "CA applied", value: 8 },
      { source: "No CA applied", target: "No MFA", value: 2 },
      { source: "CA applied", target: "No MFA", value: 3 },
      { source: "CA applied", target: "MFA", value: 5 },
      { source: "No CA applied", target: "MFA", value: null },
    ],
  },
  OverviewCaDevicesAllUsers: {
    description: "Golden user sign-ins split by device management and compliance.",
    nodes: [
      { source: "User sign in", target: "Unmanaged", value: 4 },
      { source: "User sign in", target: "Managed", value: 6 },
      { source: "Unmanaged", target: "Non-compliant", value: 4 },
      { source: "Managed", target: "Compliant", value: 5 },
      { source: "Managed", target: "Non-compliant", value: 1 },
      { source: "Unmanaged", target: "Compliant", value: 0 },
    ],
  },
};

const tests = report.Tests.map((test) => ({
  TestId: test.TestId,
  TestStatus: test.TestStatus,
  TestRisk: test.TestRisk,
  TestPillar: test.TestPillar,
  TestCategory: test.TestCategory,
  TestImpact: test.TestImpact,
  TestImplementationCost: test.TestImplementationCost,
  SkippedReason: test.SkippedReason,
  TestAppliesTo: test.TestAppliesTo,
}));

const visualTests = report.Tests.map((test) => ({
  ...test,
  TestTitle: `Golden test ${test.TestId}`,
  TestResult: "",
  TestSkipped: "",
  TestDescription: "",
  SkippedReason: test.SkippedReason ? "Golden skipped reason" : null,
}));

const fixture = {
  source: "ZeroTrustReport99/zt-export/ZeroTrustAssessmentReport.json",
  metadata: {
    ExecutedAt: report.ExecutedAt,
    TenantId: "00000000-0000-0000-0000-000000000000",
    TenantName: "Golden Tenant",
    Domain: "example.test",
    Account: "account@example.test",
    CurrentVersion: report.CurrentVersion,
    LatestVersion: report.LatestVersion,
  },
  TestResultSummary: report.TestResultSummary,
  TenantOverview: report.TenantInfo?.TenantOverview ?? null,
  optionalSections: {
    DeviceOverview: Boolean(report.TenantInfo?.DeviceOverview),
    ConfigWindowsEnrollment: Boolean(report.TenantInfo?.ConfigWindowsEnrollment),
    ConfigDeviceEnrollmentRestriction: Boolean(report.TenantInfo?.ConfigDeviceEnrollmentRestriction),
    ConfigDeviceCompliancePolicies: Boolean(report.TenantInfo?.ConfigDeviceCompliancePolicies),
    ConfigDeviceAppProtectionPolicies: Boolean(report.TenantInfo?.ConfigDeviceAppProtectionPolicies),
    sankey: Object.fromEntries(
      sankeyKeys.map((key) => [
        key,
        {
          present: Boolean(syntheticSankeyData[key] ?? report.TenantInfo?.[key]),
          nodes: (syntheticSankeyData[key] ?? report.TenantInfo?.[key])?.nodes?.length ?? 0,
        },
      ])
    ),
  },
  tests,
};

await mkdir(path.dirname(outputPath), { recursive: true });
await writeFile(outputPath, `${JSON.stringify(fixture, null, 2)}\n`);

const visualFixture = {
  ...report,
  TenantId: "00000000-0000-0000-0000-000000000000",
  TenantName: "Golden Tenant",
  Domain: "example.test",
  Account: "account@example.test",
  IsDemo: false,
  Tests: visualTests,
  TenantInfo: {
    ...report.TenantInfo,
    ...syntheticSankeyData,
  },
};

await writeFile(visualOutputPath, `${JSON.stringify(visualFixture, null, 2)}\n`);

console.log(`Wrote ${path.relative(reportRoot, outputPath)} from ${path.relative(repoRoot, sourcePath)}`);
console.log(`Wrote ${path.relative(reportRoot, visualOutputPath)} from ${path.relative(repoRoot, sourcePath)}`);
