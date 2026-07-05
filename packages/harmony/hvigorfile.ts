import { hvigor } from '@ohos/hvigor-ohos-plugin';

export default {
  system: hvigor,
  plugins: [],
  config: {
    // Hook into the build to ensure workspace npm dependencies are built
    // before the ArkTS compiler resolves them
    hooks: {
      // Pre-sync: ensure @getpaseo/client, @getpaseo/protocol, @getpaseo/highlight
      // are built (they emit .js + .d.ts to dist/)
      beforeSync: async () => {
        // This runs inside the hvigor Node.js environment
        // In CI / dev, the monorepo build:app-deps task should be run first
      }
    }
  }
};
