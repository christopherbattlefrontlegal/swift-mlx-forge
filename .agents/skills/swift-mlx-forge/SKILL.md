```markdown
# swift-mlx-forge Development Patterns

> Auto-generated skill from repository analysis

## Overview
This skill teaches you the development patterns and coding conventions used in the `swift-mlx-forge` repository, a Swift codebase with a focus on maintainable structure and clear commit practices. You'll learn how to structure files, write imports/exports, follow commit conventions, and organize tests, even in the absence of a formal framework.

## Coding Conventions

### File Naming
- Use **camelCase** for file names.
  - Example: `matrixOps.swift`, `imageLoader.swift`

### Import Style
- Use **relative imports** to reference local modules or files.
  - Example:
    ```swift
    import ../utils/mathHelpers
    ```

### Export Style
- Use **named exports** to expose specific functions, classes, or structs.
  - Example:
    ```swift
    public struct Matrix { ... }
    public func multiply(_ a: Matrix, _ b: Matrix) -> Matrix { ... }
    ```

### Commit Messages
- Follow **conventional commit** style.
- Use the `chore` prefix for maintenance or non-feature changes.
- Keep commit messages concise (average ~36 characters).
  - Example:  
    ```
    chore: update dependencies
    ```

## Workflows

### Code Maintenance
**Trigger:** When updating dependencies, refactoring, or making non-feature changes  
**Command:** `/chore`

1. Make your changes in the codebase.
2. Stage your changes:  
   ```
   git add .
   ```
3. Commit using the `chore` prefix:  
   ```
   git commit -m "chore: describe your change"
   ```
4. Push your changes to the repository.

### Adding New Features or Modules
**Trigger:** When implementing new functionality  
**Command:** `/add-module`

1. Create a new Swift file using camelCase naming.
2. Write your code, using relative imports as needed.
3. Export your structs, classes, or functions with named exports.
4. Add or update corresponding test files (see Testing Patterns).
5. Commit your changes with a descriptive message.

### Writing and Running Tests
**Trigger:** When adding or updating tests  
**Command:** `/test`

1. Create or update test files using the `*.test.*` pattern (e.g., `matrixOps.test.swift`).
2. Write test cases for your modules or functions.
3. Run tests using your preferred method (framework not specified).
4. Commit test changes with a relevant message.

## Testing Patterns

- Test files follow the `*.test.*` naming convention.
  - Example: `matrixOps.test.swift`
- The testing framework is **unknown**; use standard Swift testing approaches or your preferred framework.
- Place test files alongside or near the code they test for clarity.

**Example test file:**
```swift
import ../matrixOps

func testMatrixMultiplication() {
    // Arrange
    let a = Matrix(...)
    let b = Matrix(...)
    // Act
    let result = multiply(a, b)
    // Assert
    assert(result == expected)
}
```

## Commands
| Command      | Purpose                                      |
|--------------|----------------------------------------------|
| /chore       | For maintenance, refactoring, or dependency updates |
| /add-module  | For adding new features or modules           |
| /test        | For writing and running tests                |
```
