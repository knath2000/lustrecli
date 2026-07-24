export class AuthStatusSequence {
  private value = 0;

  beginPoll(): number { return this.value; }
  beginAction(): number { this.value += 1; return this.value; }
  acceptsPoll(value: number): boolean { return value === this.value; }
  acceptsAction(value: number): boolean { return value === this.value; }
}
