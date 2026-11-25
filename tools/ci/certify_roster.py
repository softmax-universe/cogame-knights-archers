"""Certify the ordinary knights-archers roster using an HTTP fixture for its model seats."""

import argparse
import json
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

from certification_reply import reply
from coworld.certifier import certify_coworld
from coworld.runner.runner import run_coworld_episode


class ModelFixture(BaseHTTPRequestHandler):
    def do_POST(self):
        request = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
        action = reply(request, int(self.headers["X-Coworld-Player-Slot"]))
        response = {
            "content": [{"type": "text", "text": action}],
            "stop_reason": "end_turn",
            "choices": [{"message": {"role": "assistant", "content": action}, "finish_reason": "stop"}],
        }
        payload = json.dumps(response).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(payload)))
        self.end_headers()
        self.wfile.write(payload)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("manifest", type=Path)
    parser.add_argument("--docker-host", required=True, help="Host address reachable by player containers")
    args = parser.parse_args()
    with ThreadingHTTPServer(("0.0.0.0", 0), ModelFixture) as server:
        threading.Thread(target=server.serve_forever, daemon=True).start()
        endpoint = f"http://{args.docker_host}:{server.server_port}"

        def run_roster(job, artifacts, timeout):
            model_slots = {
                slot: {"COWORLD_LLM_ENDPOINT": endpoint}
                for slot, player in enumerate(job.players)
                if player.env.get("COWORLD_LLM_ENABLED") == "true"
            }
            run_coworld_episode(job, artifacts, timeout_seconds=timeout,
                                secret_env={"COWORLD_LLM_ENDPOINT": endpoint},
                                player_secret_env=model_slots, require_websocket_pong=True)

        result = certify_coworld(args.manifest, timeout_seconds=300, episode_runner=run_roster)
        print(f"Certified {len(result.step_results)} steps; artifacts in {result.artifacts.workspace}")
        server.shutdown()


if __name__ == "__main__":
    main()
