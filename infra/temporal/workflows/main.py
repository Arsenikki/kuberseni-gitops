from temporalio import workflow

from workflows.install import InstallWorkflow
from workflows.upgrade import UpgradeWorkflow


@workflow.defn
class MainWorkflow:
    def __init__(self):
        self.install_child = None
        self.upgrade_child = None
        self._install_approval_received = False
        self._upgrade_approval_received = False

    @workflow.signal
    async def approve_install(self):
        self._install_approval_received = True
        if self.install_child:
            await self.install_child.signal("approve_install")

    @workflow.signal
    async def approve_upgrade(self):
        self._upgrade_approval_received = True
        if self.upgrade_child:
            await self.upgrade_child.signal("approve_upgrade")

    @workflow.run
    async def run(self, env: str, only_upgrade: bool = False) -> str:
        tq = workflow.info().task_queue

        install_result = "skipped"
        if not only_upgrade:
            install_id = f"{env}-install"
            workflow.logger.info(f"[{env}] starting install child: {install_id}")
            self.install_child = await workflow.start_child_workflow(
                InstallWorkflow.run,
                env,
                id=install_id,
                task_queue=tq,
            )
            
            # Wait for install approval signal from user
            workflow.logger.info(f"[{env}] waiting for install approval...")
            await workflow.wait_condition(lambda: self._install_approval_received)
            await self.install_child.signal("approve_install")
            
            # Wait for install to complete and get result
            try:
                workflow.logger.info(f"[{env}] waiting for install to complete...")
                install_result = await self.install_child.result()
                workflow.logger.info(f"[{env}] install completed: {install_result}")
            except Exception as e:
                workflow.logger.error(f"[{env}] install child result error: {e}")
                install_result = f"install-failed: {e}"
        else:
            workflow.logger.info(f"[{env}] skipping install (only_upgrade=true)")

        upgrade_id = f"{env}-upgrade"
        workflow.logger.info(f"[{env}] starting upgrade child: {upgrade_id}")
        self.upgrade_child = await workflow.start_child_workflow(
            UpgradeWorkflow.run,
            env,
            id=upgrade_id,
            task_queue=tq,
        )
        
        # Wait for upgrade approval signal from user
        workflow.logger.info(f"[{env}] waiting for upgrade approval...")
        await workflow.wait_condition(lambda: self._upgrade_approval_received)
        await self.upgrade_child.signal("approve_upgrade")
        
        # Wait for upgrade to complete and get result  
        try:
            workflow.logger.info(f"[{env}] waiting for upgrade to complete...")
            upgrade_result = await self.upgrade_child.result()
            workflow.logger.info(f"[{env}] upgrade completed: {upgrade_result}")
        except Exception as e:
            workflow.logger.error(f"[{env}] upgrade child result error: {e}")
            upgrade_result = f"upgrade-failed: {e}"

        return f"main-ok env={env} install={install_result} upgrade={upgrade_result}"
