import { describe, expect, it } from "vitest";

import { buildAssessmentChartData } from "@/lib/report-derived-data";
import type { TestResultSummaryData } from "@/config/report-data";

import fixture from "./fixtures/zero-trust-report-golden.json";

type GoldenTest = {
  TestId: string | number;
  TestStatus: string | null;
  TestRisk: string | null;
  TestPillar: string | null;
  TestCategory: string | null;
};

type GoldenFixture = {
  metadata: {
    CurrentVersion: string;
    LatestVersion: string;
  };
  TestResultSummary: TestResultSummaryData;
  TenantOverview: Record<string, number> | null;
  optionalSections: unknown;
  tests: GoldenTest[];
};

const goldenFixture = fixture as GoldenFixture;

function countBy(tests: GoldenTest[], key: keyof GoldenTest) {
  return Object.fromEntries(
    Object.entries(
      tests.reduce<Record<string, number>>((counts, test) => {
        const value = String(test[key] ?? "Not set");
        counts[value] = (counts[value] ?? 0) + 1;
        return counts;
      }, {})
    ).sort(([left], [right]) => left.localeCompare(right))
  );
}

function sortedActionableTestIds(tests: GoldenTest[]) {
  return tests
    .filter((test) => test.TestStatus === "Failed" || test.TestStatus === "Error")
    .map((test) => String(test.TestId))
    .sort((left, right) => left.localeCompare(right, undefined, { numeric: true }));
}

describe("ZeroTrustReport99 golden fixture", () => {
  it("matches the report shape generated from the exported JSON", () => {
    expect({
      versions: {
        current: goldenFixture.metadata.CurrentVersion,
        latest: goldenFixture.metadata.LatestVersion,
      },
      tenantOverview: goldenFixture.TenantOverview,
      testCount: goldenFixture.tests.length,
      testStatusCounts: countBy(goldenFixture.tests, "TestStatus"),
      pillarCounts: countBy(goldenFixture.tests, "TestPillar"),
      riskCounts: countBy(goldenFixture.tests, "TestRisk"),
      optionalSections: goldenFixture.optionalSections,
      actionableTestIds: sortedActionableTestIds(goldenFixture.tests),
    }).toMatchInlineSnapshot(`
      {
        "actionableTestIds": [
          "21772",
          "21773",
          "21775",
          "21776",
          "21777",
          "21787",
          "21790",
          "21791",
          "21792",
          "21793",
          "21802",
          "21803",
          "21804",
          "21807",
          "21809",
          "21810",
          "21811",
          "21813",
          "21822",
          "21824",
          "21837",
          "21841",
          "21842",
          "21844",
          "21846",
          "21848",
          "21850",
          "21860",
          "21866",
          "21867",
          "21874",
          "21886",
          "21888",
          "21953",
          "21954",
          "21955",
          "21992",
          "22124",
          "23183",
          "24518",
          "25393",
          "25405",
          "25413",
          "27000",
          "27002",
        ],
        "optionalSections": {
          "ConfigDeviceAppProtectionPolicies": false,
          "ConfigDeviceCompliancePolicies": false,
          "ConfigDeviceEnrollmentRestriction": false,
          "ConfigWindowsEnrollment": false,
          "DeviceOverview": false,
          "sankey": {
            "OverviewAuthMethodsAllUsers": {
              "nodes": 8,
              "present": true,
            },
            "OverviewAuthMethodsPrivilegedUsers": {
              "nodes": 8,
              "present": true,
            },
            "OverviewCaDevicesAllUsers": {
              "nodes": 6,
              "present": true,
            },
            "OverviewCaMfaAllUsers": {
              "nodes": 6,
              "present": true,
            },
          },
        },
        "pillarCounts": {
          "Data": 39,
          "Devices": 34,
          "Identity": 131,
          "Network": 67,
        },
        "riskCounts": {
          "High": 151,
          "Low": 20,
          "Medium": 100,
        },
        "tenantOverview": {
          "ApplicationCount": 63,
          "DeviceCount": 1,
          "GroupCount": 8,
          "GuestCount": 1,
          "ManagedDeviceCount": 0,
          "UserCount": 4,
        },
        "testCount": 271,
        "testStatusCounts": {
          "Error": 1,
          "Failed": 44,
          "Investigate": 2,
          "Passed": 22,
          "Planned": 34,
          "Skipped": 168,
        },
        "versions": {
          "current": "2.4.100",
          "latest": "2.3.0",
        },
      }
    `);
  });

  it("builds stable assessment chart data without NaN values", () => {
    const chartData = buildAssessmentChartData(goldenFixture.TestResultSummary);

    expect(chartData.every((point) => Number.isFinite(point.value))).toBe(true);
    expect(chartData).toMatchInlineSnapshot(`
      [
        {
          "activity": "network",
          "fill": "var(--color-network)",
          "value": 0,
        },
        {
          "activity": "data",
          "fill": "var(--color-stand)",
          "value": 0,
        },
        {
          "activity": "devices",
          "fill": "var(--color-exercise)",
          "value": 0,
        },
        {
          "activity": "identity",
          "fill": "var(--color-move)",
          "value": 34.92063492063492,
        },
      ]
    `);
  });
});

