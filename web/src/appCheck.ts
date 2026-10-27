import { initializeApp } from 'firebase/app';
import { getToken, initializeAppCheck, ReCaptchaEnterpriseProvider, type AppCheck } from 'firebase/app-check';

let instance: AppCheck | undefined;

export async function appCheckHeaders(): Promise<Record<string, string>> {
  if (!instance) {
    const env = import.meta.env || {};
    if (!env.VITE_FIREBASE_API_KEY || !env.VITE_FIREBASE_APP_ID || !env.VITE_RECAPTCHA_ENTERPRISE_SITE_KEY) {
      throw new Error('Website verification is not configured.');
    }
    instance = initializeAppCheck(initializeApp({
      apiKey: env.VITE_FIREBASE_API_KEY, appId: env.VITE_FIREBASE_APP_ID, projectId: 'beatavue',
    }), {
      provider: new ReCaptchaEnterpriseProvider(env.VITE_RECAPTCHA_ENTERPRISE_SITE_KEY),
      isTokenAutoRefreshEnabled: true,
    });
  }
  const { token } = await getToken(instance);
  return { 'X-Firebase-AppCheck': token };
}
