import os
import asyncio
from temporalio.worker import Worker
from temporalio.client import Client

# Workflows
from workflows.install import InstallWorkflow
from workflows.upgrade import UpgradeWorkflow
from workflows.main import MainWorkflow


async def main():
    target = os.getenv("TEMPORAL_TARGET", "localhost:7233")
    task_queue = os.getenv("TEMPORAL_TASK_QUEUE", "talos-management")

    client = await Client.connect(target)

    workflows = [InstallWorkflow, UpgradeWorkflow, MainWorkflow]

    worker = Worker(client, task_queue=task_queue, workflows=workflows)
    await worker.run()


if __name__ == "__main__":
    asyncio.run(main())
