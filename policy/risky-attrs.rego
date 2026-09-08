# Flags Terraform plan changes that are schema-legal "update in-place"
# but whose real OCI behavior is destructive — the exact category that
# caused the 2026-09-08 incident (LEARNING-LOG §15): oci_core_instance's
# source_details.source_id drifted from an unpinned "latest image" data
# source, Terraform showed it as a benign update (not ForceNew), and OCI
# re-provisioned the boot volume, wiping the OS.
#
# Run against `terraform show -json <planfile>` output:
#   conftest test --output json -p policy/ plan.json
#
# Deliberately a `warn`, not a `deny`: PR-time review should SEE this
# prominently but a human may have a legitimate reason to proceed (e.g. a
# deliberate, reviewed OS image bump). The CD workflow decides how strict
# to be at merge/apply time — see infra-cd.yml.
package main

import future.keywords.in

risky_fields := {"source_details", "metadata"}

warn[msg] {
	rc := input.resource_changes[_]
	rc.type == "oci_core_instance"
	"update" in rc.change.actions
	field := risky_fields[_]
	rc.change.before[field] != rc.change.after[field]
	msg := sprintf(
		"%s: %q changed via an 'update' action. This field is NOT ForceNew in the OCI provider schema, but OCI's real API behavior for changing it can be destructive (re-provisions the boot volume — see LEARNING-LOG §15, 2026-09-08). A clean 'no destroy' plan does not guarantee safety here. Verify by hand before merging.",
		[rc.address, field],
	)
}
