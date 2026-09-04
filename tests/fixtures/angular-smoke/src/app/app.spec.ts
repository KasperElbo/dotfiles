import { TestBed } from '@angular/core/testing';
import { App } from './app';

describe('App', () => {
  it('renders and calculates an answer', async () => {
    const fixture = TestBed.createComponent(App);
    fixture.detectChanges();

    const element = fixture.nativeElement as HTMLElement;
    element.querySelector('button')?.click();
    await fixture.whenStable();
    fixture.detectChanges();

    expect(element.querySelector('h1')?.textContent).toContain('42');
  });
});
