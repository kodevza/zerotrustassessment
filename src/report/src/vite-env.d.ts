/// <reference types="vite/client" />

declare const global: {
    basename: string
}

interface Window {
    __ZERO_TRUST_REPORT_DATA__?: import("@/config/report-data").ZeroTrustAssessmentReport;
}
