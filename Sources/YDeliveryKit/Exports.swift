// The product is one surface: `import YDeliveryKit` exposes the data half's
// public API as if it lived here, so splitting `YDeliveryData` out changed no
// consumer's import (same pattern `SQLiteData` uses for `StructuredQueriesSQLite`).
// Files inside this target still write `import YDeliveryData` for what they use —
// the export is for the module's clients, not its own sources.
@_exported import YDeliveryData
