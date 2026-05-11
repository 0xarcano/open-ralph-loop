declare module "node:fs" {
  export function existsSync(path: string): boolean
  export function readFileSync(path: string, encoding: string): string
  export function writeFileSync(path: string, data: string): void
  export function mkdirSync(path: string, options?: { recursive?: boolean }): void
  export function unlinkSync(path: string): void
  export function cpSync(src: string, dest: string, options?: { recursive?: boolean }): void
}

declare module "node:os" {
  export function homedir(): string
}

declare module "node:path" {
  export function dirname(path: string): string
  export function extname(path: string): string
  export function isAbsolute(path: string): boolean
  export function join(...paths: string[]): string
  export function relative(from: string, to: string): string
  export function resolve(...paths: string[]): string
}

declare module "node:url" {
  export function fileURLToPath(url: string): string
}

declare const process: {
  cwd(): string
}

interface ImportMeta {
  url: string
}
