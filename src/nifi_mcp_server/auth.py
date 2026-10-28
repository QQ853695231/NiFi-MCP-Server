from __future__ import annotations

import base64
from typing import Callable, Optional, Tuple

import requests


class KnoxAuthFactory:
	def __init__(
		self,
		gateway_url: str,
		token: Optional[str],
		cookie: Optional[str],
		user: Optional[str],
		password: Optional[str],
		token_endpoint: Optional[str],
		passcode_token: Optional[str],
		verify: bool | str,
		nifi_api_base: Optional[str] = None,
		nifi_token: Optional[str] = None,
		nifi_username: Optional[str] = None,
		nifi_password: Optional[str] = None,
		nifi_token_endpoint: Optional[str] = None,
	):
		self.gateway_url = gateway_url.rstrip("/") if gateway_url else ""
		self.token = token
		self.cookie = cookie
		self.user = user
		self.password = password
		self.token_endpoint = token_endpoint or (
			f"{self.gateway_url}/knoxtoken/api/v1/token" if self.gateway_url else None
		)
		self.passcode_token = passcode_token
		self.verify = verify

		# Standalone (non-Knox) NiFi auth
		self.nifi_api_base = nifi_api_base
		self.nifi_token = nifi_token
		self.nifi_username = nifi_username
		self.nifi_password = nifi_password
		self.nifi_token_endpoint = nifi_token_endpoint or (
			f"{self.nifi_api_base.rstrip('/')}/access/token" if self.nifi_api_base else None
		)

	def build_session(self) -> requests.Session:
		session = requests.Session()
		session.verify = self.verify

		# Priority: Explicit Cookie -> Knox token (as cookie for CDP) -> Passcode token ->
		#           Basic creds token exchange -> NIFI_TOKEN (Bearer) -> NiFi username/password login
		if self.cookie:
			session.headers["Cookie"] = self.cookie
			return session
		
		if self.token:
			# For CDP NiFi, Knox JWT tokens must be sent as cookies, not Bearer headers
			session.headers["Cookie"] = f"hadoop-jwt={self.token}"
			return session


		if self.passcode_token:
			# Prefer exchanging passcode for JWT via knoxtoken endpoint when available
			if self.token_endpoint:
				jwt = self._exchange_passcode_for_jwt()
				session.headers["Authorization"] = f"Bearer {jwt}"
				return session
			# Fallback: send passcode as header (may not work on all deployments)
			session.headers["X-Knox-Passcode"] = self.passcode_token
			return session

		if self.user and self.password and self.token_endpoint:
			jwt = self._fetch_knox_token()
			session.headers["Authorization"] = f"Bearer {jwt}"
			return session

		if self.nifi_token:
			# Standalone NiFi: JWT goes in the Authorization header, not a hadoop-jwt cookie
			session.headers["Authorization"] = f"Bearer {self.nifi_token}"
			return session

		if self.nifi_username and self.nifi_password and self.nifi_token_endpoint:
			# Standalone NiFi login identity provider (form-encoded POST /access/token)
			session.headers["Authorization"] = f"Bearer {self._nifi_login()}"
			return session

		return session

	def build_session_with_refresh(self) -> Tuple[requests.Session, Optional[Callable[[], None]]]:
		"""Build the auth session plus an optional refresh callback used on HTTP 401.

		Only the NIFI_USERNAME/NIFI_PASSWORD login path can re-authenticate when the
		JWT expires; static tokens/cookies cannot be refreshed automatically.
		"""
		session = self.build_session()
		refresh: Optional[Callable[[], None]] = None
		# Only attach refresh when the session actually uses the NiFi login path
		# (i.e., no higher-priority KNOX_* auth is configured).
		uses_nifi_login = bool(
			self.nifi_username and self.nifi_password and self.nifi_token_endpoint
			and not self.cookie and not self.token and not self.passcode_token
		)
		if uses_nifi_login:
			def refresh() -> None:
				session.headers["Authorization"] = f"Bearer {self._nifi_login()}"
		return session, refresh

	def _nifi_login(self) -> str:
		"""Login to a standalone NiFi via POST /access/token (form-encoded); returns the raw JWT."""
		resp = requests.post(
			self.nifi_token_endpoint,
			data={"username": self.nifi_username, "password": self.nifi_password},
			verify=self.verify,
			timeout=15,
		)
		try:
			resp.raise_for_status()
		except requests.HTTPError as e:
			raise RuntimeError(
				f"NiFi login failed ({resp.status_code}) at {self.nifi_token_endpoint}: "
				"check NIFI_USERNAME / NIFI_PASSWORD / NIFI_API_BASE"
			) from e
		token = resp.text.strip()
		if not token:
			raise RuntimeError(f"NiFi login endpoint {self.nifi_token_endpoint} returned an empty token")
		return token

	def _fetch_knox_token(self) -> str:
		# Default Knox token endpoint returns raw JWT or JSON with token fields
		resp = requests.get(
			self.token_endpoint,
			auth=(self.user, self.password),
			verify=self.verify,
			timeout=15,
		)
		resp.raise_for_status()
		try:
			data = resp.json()
			return data.get("access_token") or data.get("token") or data.get("accessToken")
		except ValueError:
			text = resp.text.strip()
			# Some envs return Base64-encoded token; detect and decode if needed
			try:
				decoded = base64.b64decode(text).decode("utf-8")
				if decoded.count(".") == 2:
					return decoded
			except Exception:
				pass
			return text

	def _exchange_passcode_for_jwt(self) -> str:
		"""Exchange Knox passcode token for JWT using Basic auth pattern passcode:<token>."""
		if not (self.passcode_token and self.token_endpoint):
			raise RuntimeError("Passcode token exchange requires token_endpoint and passcode token")
		import base64
		header = {
			"Authorization": "Basic " + base64.b64encode(f"passcode:{self.passcode_token}".encode()).decode(),
			"X-Requested-By": "nifi-mcp-server",
		}
		resp = requests.get(self.token_endpoint, headers=header, verify=self.verify, timeout=15)
		resp.raise_for_status()
		try:
			data = resp.json()
			return data.get("access_token") or data.get("token") or data.get("accessToken")
		except ValueError:
			return resp.text.strip()


