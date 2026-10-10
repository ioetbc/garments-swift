import { defineConfig, globalIgnores } from "eslint/config";
import nextVitals from "eslint-config-next/core-web-vitals";
import nextTs from "eslint-config-next/typescript";

const eslintConfig = defineConfig([
  ...nextVitals,
  ...nextTs,
  // Override default ignores of eslint-config-next.
  globalIgnores([
    // Default ignores of eslint-config-next:
    ".next/**",
    "out/**",
    "build/**",
    "next-env.d.ts",
    "convex/_generated/**",
  ]),
  // Destructuring away fields (e.g. Convex system fields) is the intended use.
  { rules: { "@typescript-eslint/no-unused-vars": ["warn", { ignoreRestSiblings: true }] } },
  // Backend errors are tagged (Schema.TaggedError) inside Effect or ConvexError at the handler edge.
  {
    files: ["convex/**/*.ts"],
    rules: {
      "no-restricted-syntax": [
        "error",
        { selector: "NewExpression[callee.name='Error']", message: "Use a Schema.TaggedError inside Effect, or ConvexError at the handler edge." },
      ],
    },
  },
]);

export default eslintConfig;
