import mikecannLint from "mikecann-lint";

// e2e/ holds Playwright fixtures, whose use() isn't a React hook.
export default await mikecannLint({ root: import.meta.dirname, notReact: ["e2e/**"] });
