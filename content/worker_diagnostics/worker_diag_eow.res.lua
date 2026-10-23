-- "Worker Diagnostics" card in the industry window, right after the game's Boosters card (order 20).
function data()
	return {
		type = "react-plugin ::IndustryEowExtensionPoint",
		data = {
			filePath = resolve("worker_diag_ui.script@WorkerDiagPlugin"),
			condition = resolve("worker_diag_ui.script@conditionWorkerDiag"),
			order = 25,
		}
	}
end
