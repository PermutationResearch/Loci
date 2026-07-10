const api = typeof browser !== "undefined" ? browser : chrome;
const lociPairingEndpoint = "http://127.0.0.1:17641/pairing-token";

export async function getAuthToken() {
  const result = await api.storage.local.get("lociAuthToken");
  if (result.lociAuthToken) {
    return result.lociAuthToken;
  }
  return pairWithLoci();
}

async function pairWithLoci() {
  const response = await fetch(lociPairingEndpoint, {
    method: "GET",
    headers: {
      "X-Loci-Extension": "browser-extension"
    }
  });

  if (!response.ok) {
    throw new Error(`Loci pairing returned ${response.status}`);
  }

  const body = await response.json();
  if (!body.token) {
    throw new Error("Loci pairing did not return a token");
  }

  await api.storage.local.set({ lociAuthToken: body.token });
  return body.token;
}

export async function clearAuthToken() {
  await api.storage.local.remove("lociAuthToken");
}

export async function postToLoci(endpoint, payload) {
  const token = await getAuthToken();
  let response = await postWithToken(endpoint, payload, token);

  if (response.status === 401) {
    await clearAuthToken();
    response = await postWithToken(endpoint, payload, await getAuthToken());
  }

  if (!response.ok) {
    throw new Error(`Loci returned ${response.status}`);
  }
}

async function postWithToken(endpoint, payload, token) {
  return fetch(endpoint, {
    method: "POST",
    headers: {
      "Content-Type": "application/json",
      "Authorization": `Bearer ${token}`
    },
    body: JSON.stringify(payload)
  });
}
