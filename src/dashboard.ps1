# watch and nyan are drawn by the compiled reader: native/src/dashboard.rs and watch.rs.
# Nothing is defined here. The live preview harness of a release installed before the
# reader drew the dashboard reads this file from a candidate before it asks that
# candidate's reader, so the file stays until no such release is installed.
