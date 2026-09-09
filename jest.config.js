/** @type {import('jest').Config} */
module.exports = {
  preset: 'ts-jest',
  testEnvironment: 'node',
  rootDir: '.',
  testMatch: ['<rootDir>/tests/**/*.spec.ts'],
  collectCoverageFrom: ['src/**/*.ts'],
  coveragePathIgnorePatterns: ['/node_modules/'],
};
