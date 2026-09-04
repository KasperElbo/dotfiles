import { Component, signal } from '@angular/core';

@Component({
  selector: 'app-root',
  template: `
    <h1>Angular smoke: {{ answer() }}</h1>
    <button type="button" (click)="calculate()">Calculate</button>
  `,
})
export class App {
  protected readonly answer = signal(0);

  protected calculate(): void {
    const answer = 6 * 7;
    this.answer.set(answer);
  }
}
