import { SignInButton, UserButton } from "@clerk/nextjs";
import { auth } from "@clerk/nextjs/server";
import { DevicesView } from "./devices-view";

export default async function DevicesPage() {
  const { isAuthenticated } = await auth();
  return <main className="cloud-devices"><header><div><p className="eyebrow">Lustre Cloud · Experimental</p><h1>Your devices</h1><p>Pair a Mac for experimental presence only. Local downloads, queues, WebDAV, feeds, and auth remain local-first.</p></div>{isAuthenticated && <UserButton />}</header>{isAuthenticated ? <DevicesView /> : <section className="cloud-empty"><h2>Sign in to manage experimental devices</h2><SignInButton><button className="initiate-button">Sign in</button></SignInButton></section>}</main>;
}
