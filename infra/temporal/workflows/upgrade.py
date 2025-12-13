from datetime import timedelta
from temporalio import workflow


@workflow.defn
class UpgradeWorkflow:
    def __init__(self):
        self._apply_approved = False

    @workflow.signal
    def approve_upgrade(self):
        self._apply_approved = True

    @workflow.run
    async def run(self, env: str) -> str:
        steps = [
            ("prechecks", False),
            ("control-plane-upgrade", True),
            ("workers-upgrade", False),
            ("post-checks", False),
            ("smoke-tests", False),
        ]

        for idx, (name, needs_approval) in enumerate(steps, start=1):
            workflow.logger.info(f"[{env}] starting step {idx}: {name}")
            if needs_approval:
                workflow.logger.info(f"[{env}] waiting for user signal: approve_apply")
                await workflow.wait_condition(lambda: self._apply_approved)
                workflow.logger.info(f"[{env}] approval received, continuing")
            # Brief pause to ensure deterministic execution
            try:
                await workflow.wait_condition(lambda: False, timeout=0.001)
            except:
                pass
            workflow.logger.info(f"[{env}] completed step {idx}: {name}")

        return f"upgrade-ok env={env}"
