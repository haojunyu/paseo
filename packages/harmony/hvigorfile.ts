import { appTasks } from '@ohos/hvigor-ohos-plugin';
import * as fs from 'fs';
import * as path from 'path';
import { execSync } from 'child_process';

/**
 * Monorepo workspace → oh_modules symlink map.
 *
 * The ArkTS compiler resolves packages from entry/oh_modules/. Since ohpm
 * cannot install npm packages (different registry, different package format),
 * we bypass ohpm and set up symlinks directly pointing to the built npm
 * workspace packages and their hoisted node_modules/ dependencies.
 *
 * Each workspace package listed here MUST have an oh-package.json5 at its
 * root (created alongside package.json) with at least name, version, main,
 * and types fields so the ArkTS resolver can find the entry points.
 *
 * To add a new npm dependency:
 * 1. Add it to the WORKSPACE_PACKAGES or NPM_PACKAGES list below
 * 2. Ensure it has an oh-package.json5 (workspace) or is installed in the
 *    monorepo root node_modules/ (npm registry)
 */
const WORKSPACE_PACKAGES = [
  '@getpaseo/client',
  '@getpaseo/protocol',
  '@getpaseo/relay',
  '@getpaseo/highlight',
];

/**
 * npm registry packages that the harmony entry imports directly or that are
 * transitive dependencies of workspace packages. Symlinked from the monorepo
 * root node_modules/ into entry/oh_modules/.
 */
const NPM_PACKAGES = [
  'zod',          // transitive dep of @getpaseo/client + @getpaseo/protocol
  'markdown-it',  // planned for markdown rendering in harmony
  'mnemonic-id',  // planned for ID generation in harmony
];

function setupOhModules(): void {
  const repoRoot = path.resolve(__dirname, '../..');
  const ohModulesDir = path.resolve(__dirname, 'entry/oh_modules');

  // Create oh_modules if it doesn't exist (ohpm creates it during install).
  // Do NOT delete the directory — ohpm-installed @ohos/* packages live here.
  fs.mkdirSync(ohModulesDir, { recursive: true });

  // Symlink workspace packages from their source directories
  for (const pkgName of WORKSPACE_PACKAGES) {
    const [scope, name] = pkgName.split('/');
    const srcPath = path.resolve(repoRoot, 'packages', name);
    const destDir = path.resolve(ohModulesDir, scope, name);

    if (!fs.existsSync(srcPath)) {
      console.warn(`[harmony:hvigor] Skipping ${pkgName}: source not found at ${srcPath}`);
      continue;
    }

    fs.mkdirSync(path.dirname(destDir), { recursive: true });
    fs.symlinkSync(srcPath, destDir, 'dir');
    console.log(`[harmony:hvigor] Symlinked ${pkgName} → ${path.relative(ohModulesDir, srcPath)}`);
  }

  // Symlink npm registry packages from monorepo root node_modules
  const npmModulesDir = path.resolve(repoRoot, 'node_modules');
  for (const pkgName of NPM_PACKAGES) {
    const srcPath = path.resolve(npmModulesDir, pkgName);
    const destPath = path.resolve(ohModulesDir, pkgName);

    if (!fs.existsSync(srcPath)) {
      console.warn(`[harmony:hvigor] Skipping ${pkgName}: not found in node_modules. Run 'npm install' at repo root.`);
      continue;
    }

    fs.symlinkSync(srcPath, destPath, 'dir');
    console.log(`[harmony:hvigor] Symlinked ${pkgName} → node_modules/${pkgName}`);
  }
}

export default {
  system: appTasks,
  plugins: [],
  config: {
    hooks: {
      beforeSync: async () => {
        const repoRoot = path.resolve(__dirname, '../..');

        // Ensure workspace packages are built (they emit .js + .d.ts to dist/)
        try {
          console.log('[harmony:hvigor] Building workspace dependencies...');
          execSync('npm run build:server-deps', {
            cwd: repoRoot,
            stdio: 'pipe',
            timeout: 120_000,
          });
          console.log('[harmony:hvigor] Workspace dependencies built.');
        } catch (err: any) {
          const stderr = err.stderr?.toString() ?? '';
          console.warn(
            '[harmony:hvigor] Build step failed (dependencies may already be built):\n' +
              stderr.slice(-500),
          );
        }

        setupOhModules();
      },
    },
  },
};
