import { SignInButton } from "@clerk/nextjs";
import { auth } from "@clerk/nextjs/server";
import { CloudFullDashboard } from "./cloud-full-dashboard";

export default async function Home() {
  const { isAuthenticated } = await auth();
  if (!isAuthenticated) return <main className="cloud-devices"><section className="cloud-empty"><p className="eyebrow">Lustre Cloud</p><h1>Sign in to open your dashboard</h1><p>Your paired Macs, job history, and remote controls are available only to your Cloud account.</p><SignInButton><button className="initiate-button">Sign in</button></SignInButton></section></main>;
  return <CloudFullDashboard />;
}
