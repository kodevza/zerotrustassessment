import type { TestResultSummaryData } from "@/config/report-data";

type AssessmentPillar = {
  activity: string;
  fill: string;
  passedKey: keyof TestResultSummaryData;
  totalKey: keyof TestResultSummaryData;
  optional?: boolean;
};

const assessmentPillars: AssessmentPillar[] = [
  {
    activity: "ai",
    fill: "var(--color-ai)",
    passedKey: "AIPassed",
    totalKey: "AITotal",
    optional: true,
  },
  {
    activity: "secops",
    fill: "var(--color-secops)",
    passedKey: "SecOpsPassed",
    totalKey: "SecOpsTotal",
    optional: true,
  },
  {
    activity: "infrastructure",
    fill: "var(--color-infrastructure)",
    passedKey: "InfrastructurePassed",
    totalKey: "InfrastructureTotal",
    optional: true,
  },
  {
    activity: "network",
    fill: "var(--color-network)",
    passedKey: "NetworkPassed",
    totalKey: "NetworkTotal",
    optional: true,
  },
  {
    activity: "data",
    fill: "var(--color-stand)",
    passedKey: "DataPassed",
    totalKey: "DataTotal",
    optional: true,
  },
  {
    activity: "devices",
    fill: "var(--color-exercise)",
    passedKey: "DevicesPassed",
    totalKey: "DevicesTotal",
  },
  {
    activity: "identity",
    fill: "var(--color-move)",
    passedKey: "IdentityPassed",
    totalKey: "IdentityTotal",
  },
];

const isNumber = (value: unknown): value is number => typeof value === "number";

export const percentage = (passed: number, total: number) =>
  total > 0 ? (passed / total) * 100 : 0;

export function buildAssessmentChartData(summary: TestResultSummaryData) {
  return assessmentPillars.flatMap(({ activity, fill, passedKey, totalKey, optional }) => {
    const passed = summary[passedKey];
    const total = summary[totalKey];

    if (optional && (!isNumber(passed) || !isNumber(total))) {
      return [];
    }

    return [{
      activity,
      value: percentage(Number(passed), Number(total)),
      fill,
    }];
  });
}

