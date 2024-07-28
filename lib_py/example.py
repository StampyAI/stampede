from typing import Optional, Dict


def process(cfg, event) -> Optional[Dict]:
    if event[b"body"] == b"ping python":
        return {
            "confidence": 10,
            "text": "pong!",
            "why": ["They pinged so I ponged!"],
        }
    else:
        return None
